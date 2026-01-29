--- === hs.window.filter ===
---
--- Filter windows by application, title, location on screen and more,
--- and easily subscribe to events on these windows
---
--- This is a complete rewrite of the original hs.window.filter module,
--- maintaining full API compatibility while improving performance,
--- reliability, and maintainability.
---
--- ## Development Notes
---
--- **Style**: Follows `window.lua` conventions (local caching, minimal whitespace)
---
--- **Testing**: Load via hs CLI for manual testing:
--- ```
--- /Users/dmg/bin/osx/hs -c 'local wf = dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua"); print(wf._VERSION)'
--- ```
---
--- **Test utilities**:
--- ```
--- /Users/dmg/bin/osx/hs -c '
--- local wf = dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua")
--- -- Test safeCall with valid call
--- local win = hs.window.focusedWindow()
--- if win then
---   print("safeCall title:", wf._safeCall(win.title, win))
---   print("safeGetScreenId:", wf._safeGetScreenId(win))
--- end
--- -- Test safeCall with nil
--- print("safeCall nil fn:", wf._safeCall(nil, {}))
--- -- Test safeCall with error
--- print("safeCall error:", wf._safeCall(function() error("test") end, nil))
--- '
--- ```
---
--- @module hs.window.filter

----------------------------------------------------------------------
-- SECTION 1: LOCAL CACHING AND IMPORTS
----------------------------------------------------------------------
-- Following window.lua style: cache globals for performance
-- Use hs.* globals directly (no require) for dofile() compatibility

local pairs, ipairs, type, setmetatable = pairs, ipairs, type, setmetatable
local pcall, error, tostring, tonumber = pcall, error, tostring, tonumber
local tinsert, tremove, tsort = table.insert, table.remove, table.sort
local sformat, smatch, sfind = string.format, string.match, string.find
local floor, min, max = math.floor, math.min, math.max

----------------------------------------------------------------------
-- SECTION 2: MODULE TABLE
----------------------------------------------------------------------

local windowfilter = {}
windowfilter._VERSION = '2.0.0-dev'

----------------------------------------------------------------------
-- SECTION 3: CONFIGURATION
----------------------------------------------------------------------

--- Configuration constants for the window filter system.
--- These values can be tuned based on real-world testing.
local Config = {
  -- Timing (seconds)
  RETRY_DELAY = 0.2,              -- Delay between registration retries
  MAX_RETRIES = 5,                -- Max attempts to register window/app
  MOVED_DEBOUNCE = 0.5,           -- Debounce for windowMoved events
  TITLE_DEBOUNCE = 0.5,           -- Debounce for titleChanged events
  SPACE_CHANGE_DELAY = 0.5,       -- Delay after space switch before refresh
  ZOMBIE_CLEANUP_INTERVAL = 300,  -- Seconds between zombie app cleanup (5 min)

  -- Performance
  ACCESSIBILITY_TIMEOUT = 0.5,    -- Max wait for AX response (seconds)
  SKIP_SLOW_APPS = false,         -- If true, skip apps exceeding timeout

  -- Filtering defaults
  ALLOWED_ROLES = {
    AXStandardWindow = true,
    AXDialog = true,
    AXSystemDialog = true,
  },
}

-- Expose config for testing/tuning (prefixed with _ for internal use)
windowfilter._config = Config

----------------------------------------------------------------------
-- SECTION 4: UTILITY FUNCTIONS
----------------------------------------------------------------------

--- Safely call a method on an object, catching errors.
--- Returns nil if fn is nil, obj is nil, or call throws an error.
--- @param fn function The function/method to call
--- @param obj any The object to call the method on (self)
--- @param ... any Additional arguments to pass
--- @return any The result of the call, or nil on failure
local function safeCall(fn, obj, ...)
  if not fn then return nil end
  local ok, result = pcall(fn, obj, ...)
  if ok then
    return result
  else
    print(sformat('[wfilter] safeCall failed: %s', tostring(result)))
    return nil
  end
end

--- Safely get the screen ID for a window.
--- Returns 0 if window has no screen or any call fails.
--- @param hsWindow userdata The hs.window object
--- @return number The screen ID, or 0 on failure
local function safeGetScreenId(hsWindow)
  if not hsWindow then return 0 end
  local ok, scr = pcall(hsWindow.screen, hsWindow)
  if ok and scr then
    local ok2, id = pcall(scr.id, scr)
    if ok2 and id then
      return id
    end
  end
  return 0
end

-- Expose utilities for testing (prefixed with _ for internal use)
windowfilter._safeCall = safeCall
windowfilter._safeGetScreenId = safeGetScreenId

----------------------------------------------------------------------
-- SECTION 5: DATA STRUCTURES
----------------------------------------------------------------------

----------------------------------------------------------------------
-- WindowInfo: Snapshot of window state
----------------------------------------------------------------------
-- Captures window properties at a point in time with safe extraction.
-- Mutable properties can be updated via refresh().
-- appName/appPid are set by Tracker after construction.

local WindowInfo = {}
WindowInfo.__index = WindowInfo

--- Create a new WindowInfo from an hs.window object.
--- @param hsWindow userdata The hs.window object
--- @return table|nil WindowInfo object, or nil if hsWindow is invalid
function WindowInfo.new(hsWindow)
  if not hsWindow then return nil end

  local self = setmetatable({}, WindowInfo)

  -- Immutable properties (set once at creation)
  self.id = safeCall(hsWindow.id, hsWindow) or 0
  self.timeCreated = hs.timer.absoluteTime()

  -- Mutable properties (can change, updated via refresh)
  self.title = safeCall(hsWindow.title, hsWindow) or ''
  self.role = safeCall(hsWindow.subrole, hsWindow) or ''
  self.frame = safeCall(hsWindow.frame, hsWindow)
  self.screenId = safeGetScreenId(hsWindow)
  self.isMinimized = safeCall(hsWindow.isMinimized, hsWindow) or false
  self.isVisible = safeCall(hsWindow.isVisible, hsWindow) or false
  self.isFullscreen = safeCall(hsWindow.isFullScreen, hsWindow) or false

  -- hasTitlebar: true if window has a zoom button (standard window chrome)
  local zoomRect = safeCall(hsWindow.zoomButtonRect, hsWindow)
  self.hasTitlebar = zoomRect ~= nil

  -- Computed property
  self.isHidden = not self.isVisible and not self.isMinimized

  -- Tracking state (set by Tracker)
  self.timeFocused = 0
  self.appName = nil
  self.appPid = nil
  self.isInCurrentSpace = nil  -- Set by Tracker; nil means unknown

  -- Reference to underlying hs.window (for API calls)
  self._window = hsWindow

  return self
end

--- Refresh mutable properties from the underlying window.
--- Called after move/resize/title change events.
--- @return boolean true if refresh succeeded, false if window is invalid
function WindowInfo:refresh()
  local win = self._window
  if not win then return false end

  -- Check if window is still valid
  local id = safeCall(win.id, win)
  if not id or id ~= self.id then return false end

  -- Update mutable properties
  self.title = safeCall(win.title, win) or ''
  self.role = safeCall(win.subrole, win) or ''
  self.frame = safeCall(win.frame, win)
  self.screenId = safeGetScreenId(win)
  self.isMinimized = safeCall(win.isMinimized, win) or false
  self.isVisible = safeCall(win.isVisible, win) or false
  self.isFullscreen = safeCall(win.isFullScreen, win) or false

  local zoomRect = safeCall(win.zoomButtonRect, win)
  self.hasTitlebar = zoomRect ~= nil

  -- Recompute derived property
  self.isHidden = not self.isVisible and not self.isMinimized

  return true
end

--- String representation for debugging.
function WindowInfo:__tostring()
  return sformat('WindowInfo[%d]: "%s" (%s)', self.id, self.title, self.appName or '?')
end

-- Expose for testing
windowfilter._WindowInfo = WindowInfo

----------------------------------------------------------------------
-- AppInfo: Snapshot of application state
----------------------------------------------------------------------
-- Tracks application properties and its windows.
-- windows table is populated by Tracker.

local AppInfo = {}
AppInfo.__index = AppInfo

--- Create a new AppInfo from an hs.application object.
--- @param hsApp userdata The hs.application object
--- @param pid number The process ID
--- @return table|nil AppInfo object, or nil if hsApp is invalid
function AppInfo.new(hsApp, pid)
  if not hsApp then return nil end

  local self = setmetatable({}, AppInfo)

  -- Process identification
  self.pid = pid or safeCall(hsApp.pid, hsApp) or 0

  -- Application properties
  self.name = safeCall(hsApp.name, hsApp) or ''
  self.bundleID = safeCall(hsApp.bundleID, hsApp) or ''
  self.isHidden = safeCall(hsApp.isHidden, hsApp) or false
  self.isFrontmost = safeCall(hsApp.isFrontmost, hsApp) or false

  -- Windows tracked for this app (id -> WindowInfo)
  -- Populated by Tracker, not here
  self.windows = {}

  -- Watcher for this app's UI events (set by Tracker)
  self.watcher = nil

  -- Reference to underlying hs.application
  self._app = hsApp

  return self
end

--- Refresh application state properties.
--- @return boolean true if refresh succeeded, false if app is invalid
function AppInfo:refresh()
  local app = self._app
  if not app then return false end

  -- Check if app is still running
  local pid = safeCall(app.pid, app)
  if not pid or pid ~= self.pid then return false end

  self.isHidden = safeCall(app.isHidden, app) or false
  self.isFrontmost = safeCall(app.isFrontmost, app) or false

  return true
end

--- String representation for debugging.
function AppInfo:__tostring()
  local winCount = 0
  for _ in pairs(self.windows) do winCount = winCount + 1 end
  return sformat('AppInfo[%d]: %s (%d windows)', self.pid, self.name, winCount)
end

-- Expose for testing
windowfilter._AppInfo = AppInfo

----------------------------------------------------------------------
-- SECTION 6: FILTER RULES AND FILTER
----------------------------------------------------------------------

----------------------------------------------------------------------
-- FilterRules: Storage for filter configuration
----------------------------------------------------------------------
-- Stores override, per-app, and default filter rules.
-- Each rule is either false (reject all) or a table of criteria.

local FilterRules = {}
FilterRules.__index = FilterRules

--- Create a new FilterRules object.
--- @return table FilterRules object
function FilterRules.new()
  local self = setmetatable({}, FilterRules)
  self.override = nil       -- Applied first to all windows; false = reject all
  self.appRules = {}        -- appname -> rule table or false
  self.default = nil        -- Fallback rule; false = reject all
  return self
end

--- String representation for debugging.
function FilterRules:__tostring()
  local appCount = 0
  for _ in pairs(self.appRules) do appCount = appCount + 1 end
  return sformat('FilterRules: override=%s, apps=%d, default=%s',
    tostring(self.override ~= nil), appCount, tostring(self.default ~= nil))
end

-- Expose for testing
windowfilter._FilterRules = FilterRules

----------------------------------------------------------------------
-- Filter: Pure functions for matching windows against rules
----------------------------------------------------------------------
-- All matching logic is stateless and side-effect free.
-- Context is passed explicitly to avoid global state.

local Filter = {}

--- Match a window against a complete FilterRules structure.
--- Checks override, then app-specific, then default rules.
--- @param rules table FilterRules object
--- @param windowInfo table WindowInfo object
--- @param context table {focusedWindowId, activeAppPid}
--- @return boolean allowed, string reason
function Filter.matches(rules, windowInfo, context)
  if not rules then return true, '' end
  if not windowInfo then return false, 'nil windowInfo' end

  local appName = windowInfo.appName or ''

  -- Check override filter (applied to all windows)
  if rules.override == false then
    return false, 'override rejects all'
  end
  if rules.override then
    local ok, reason = Filter.matchesRule(rules.override, windowInfo, context)
    if not ok then
      return false, 'override: ' .. reason
    end
  end

  -- Check app-specific filter
  local appRule = rules.appRules[appName]
  if appRule == false then
    return false, 'app rejected'
  end
  if appRule then
    local ok, reason = Filter.matchesRule(appRule, windowInfo, context)
    return ok, ok and '' or ('app: ' .. reason)
  end

  -- Check default filter
  if rules.default == false then
    return false, 'default rejects all'
  end
  if rules.default then
    local ok, reason = Filter.matchesRule(rules.default, windowInfo, context)
    return ok, ok and '' or ('default: ' .. reason)
  end

  -- No filter = allow
  return true, ''
end

--- Match a window against a single rule table.
--- @param rule table Rule with filter criteria
--- @param windowInfo table WindowInfo object
--- @param context table {focusedWindowId, activeAppPid}
--- @return boolean allowed, string reason
function Filter.matchesRule(rule, windowInfo, context)
  if not rule then return true, '' end
  context = context or {}

  -- Visibility
  if rule.visible ~= nil then
    if rule.visible ~= windowInfo.isVisible then
      return false, 'visible'
    end
  end

  -- Current space
  if rule.currentSpace ~= nil then
    if rule.currentSpace ~= windowInfo.isInCurrentSpace then
      return false, 'currentSpace'
    end
  end

  -- Fullscreen
  if rule.fullscreen ~= nil then
    if rule.fullscreen ~= windowInfo.isFullscreen then
      return false, 'fullscreen'
    end
  end

  -- Focused
  if rule.focused ~= nil then
    local isFocused = (windowInfo.id == context.focusedWindowId)
    if rule.focused ~= isFocused then
      return false, 'focused'
    end
  end

  -- Active application
  if rule.activeApplication ~= nil then
    local isActive = (windowInfo.appPid == context.activeAppPid)
    if rule.activeApplication ~= isActive then
      return false, 'activeApplication'
    end
  end

  -- Allow titles (minimum length or pattern match)
  if rule.allowTitles then
    if not Filter.matchesTitleRule(rule.allowTitles, windowInfo.title) then
      return false, 'allowTitles'
    end
  end

  -- Reject titles (pattern match)
  if rule.rejectTitles then
    if Filter.matchesTitlePattern(rule.rejectTitles, windowInfo.title) then
      return false, 'rejectTitles'
    end
  end

  -- Titlebar
  if rule.hasTitlebar ~= nil then
    if rule.hasTitlebar ~= windowInfo.hasTitlebar then
      return false, 'hasTitlebar'
    end
  end

  -- Roles (check subrole against allowed list)
  local allowedRoles = rule.allowRoles or Config.ALLOWED_ROLES
  if allowedRoles ~= '*' then
    if type(allowedRoles) == 'string' then
      allowedRoles = {[allowedRoles] = true}
    elseif type(allowedRoles) == 'table' and allowedRoles[1] then
      -- Convert array to set
      local roleSet = {}
      for _, r in ipairs(allowedRoles) do roleSet[r] = true end
      allowedRoles = roleSet
    end
    if not allowedRoles[windowInfo.role] then
      return false, 'allowRoles'
    end
  end

  -- Regions and screens only apply to visible windows
  if windowInfo.isVisible then
    -- Allow regions (window must be in at least one region)
    if rule.allowRegions then
      if not Filter.matchesRegions(rule.allowRegions, windowInfo.frame) then
        return false, 'allowRegions'
      end
    end

    -- Reject regions (window must NOT be in any region)
    -- NOTE: Fixed bug from original - was using allowRegions instead of rejectRegions
    if rule.rejectRegions then
      if Filter.matchesRegions(rule.rejectRegions, windowInfo.frame) then
        return false, 'rejectRegions'
      end
    end

    -- Allow screens (window must be on at least one screen)
    if rule.allowScreens then
      local allowedScreenIds = Filter.resolveScreens(rule.allowScreens)
      if not allowedScreenIds[windowInfo.screenId] then
        return false, 'allowScreens'
      end
    end

    -- Reject screens (window must NOT be on any screen)
    if rule.rejectScreens then
      local rejectedScreenIds = Filter.resolveScreens(rule.rejectScreens)
      if rejectedScreenIds[windowInfo.screenId] then
        return false, 'rejectScreens'
      end
    end
  end

  return true, ''
end

--- Match title against allowTitles rule.
--- If rule is a number, checks minimum title length.
--- Otherwise delegates to pattern matching.
--- @param rule number|string|table The allowTitles rule
--- @param title string The window title
--- @return boolean true if title matches rule
function Filter.matchesTitleRule(rule, title)
  if type(rule) == 'number' then
    return #title >= rule
  end
  return Filter.matchesTitlePattern(rule, title)
end

--- Match title against pattern(s).
--- @param patterns string|table Pattern or list of patterns
--- @param title string The window title
--- @return boolean true if title matches any pattern
function Filter.matchesTitlePattern(patterns, title)
  if type(patterns) == 'string' then
    patterns = {patterns}
  end
  if type(patterns) ~= 'table' then
    return false
  end
  for _, pattern in ipairs(patterns) do
    if smatch(title, pattern) then
      return true
    end
  end
  return false
end

--- Match window frame against regions using 50% overlap rule.
--- Window matches if:
---   - More than 50% of window is inside a region, OR
---   - More than 50% of a region is covered by the window
--- @param regions table List of hs.geometry rects
--- @param frame table Window frame (hs.geometry rect)
--- @return boolean true if window matches any region
function Filter.matchesRegions(regions, frame)
  if not regions or not frame then return false end
  if type(regions) ~= 'table' then
    regions = {regions}
  end
  -- Ensure regions is a list (might be single rect)
  if regions.x ~= nil then
    regions = {regions}
  end

  for _, region in ipairs(regions) do
    -- Use hs.geometry intersection
    local intersection = frame:intersect(region)
    if intersection and intersection.area and intersection.area > 0 then
      local frameArea = frame.area or (frame.w * frame.h)
      local regionArea = region.area or (region.w * region.h)
      if frameArea > 0 and regionArea > 0 then
        -- Check 50% overlap rule
        if intersection.area > frameArea * 0.5 or intersection.area > regionArea * 0.5 then
          return true
        end
      end
    end
  end
  return false
end

--- Resolve screen hints to screen IDs.
--- Resolved lazily at match time for hot-plug reliability.
--- @param screenHints any Valid argument(s) for hs.screen.find()
--- @return table Set of screen IDs {[id] = true}
function Filter.resolveScreens(screenHints)
  local ids = {}
  if screenHints == nil then return ids end

  -- Normalize to list
  if type(screenHints) ~= 'table' or screenHints.id then
    -- Single screen or screen hint
    screenHints = {screenHints}
  end

  for _, hint in ipairs(screenHints) do
    local scr = nil
    -- If hint is already a screen object, use it directly
    if type(hint) == 'userdata' or (type(hint) == 'table' and hint.id) then
      scr = hint
    else
      -- Use hs.screen.find to resolve hint
      local ok, result = pcall(hs.screen.find, hint)
      if ok then scr = result end
    end

    if scr then
      local ok, id = pcall(scr.id, scr)
      if ok and id then
        ids[id] = true
      end
    end
  end

  return ids
end

-- Expose for testing
windowfilter._Filter = Filter

----------------------------------------------------------------------
-- SECTION 7: PREFILTER
----------------------------------------------------------------------
-- PreFilter decides whether to create watchers for apps/windows.
-- This is a performance optimization - avoids tracking non-GUI apps
-- and windows that will never match any filter.
-- All functions are pure and take config as parameter.

local PreFilter = {}

--- Check if an app should be tracked (watcher created).
--- Called by Tracker when a new app is detected.
--- @param hsApp userdata The hs.application object
--- @param config table PreFilter configuration
--- @return boolean shouldTrack, string reason (if false)
function PreFilter.shouldTrackApp(hsApp, config)
  if not hsApp then return false, 'nil app' end
  config = config or {}

  -- Check app:kind() - negative means no GUI
  local kind = safeCall(hsApp.kind, hsApp)
  if kind and kind < 0 then
    return false, 'not a GUI app'
  end

  local appName = safeCall(hsApp.name, hsApp) or ''
  local bundleID = safeCall(hsApp.bundleID, hsApp) or ''

  -- Check bundle ID blacklist
  if config.ignoreBundleIDs and bundleID ~= '' then
    if config.ignoreBundleIDs[bundleID] then
      return false, 'bundleID blacklisted'
    end
  end

  -- Check app name blacklist
  if config.ignoreAppNames and appName ~= '' then
    if config.ignoreAppNames[appName] then
      return false, 'appName blacklisted'
    end
  end

  -- Check app name pattern (e.g., '^QTKitServer%-')
  if config.ignoreAppPattern and appName ~= '' then
    if smatch(appName, config.ignoreAppPattern) then
      return false, 'appName matches ignore pattern'
    end
  end

  return true, nil
end

--- Check if a window should be tracked (watcher created).
--- Called by Tracker when a new window is detected.
--- Assumes app has already passed shouldTrackApp.
--- @param hsWindow userdata The hs.window object
--- @param hsApp userdata The hs.application object (for context, not re-checked)
--- @param config table PreFilter configuration
--- @return boolean shouldTrack, string reason (if false)
function PreFilter.shouldTrack(hsWindow, hsApp, config)
  if not hsWindow then return false, 'nil window' end
  config = config or {}

  -- Get window properties
  local title = safeCall(hsWindow.title, hsWindow) or ''
  local role = safeCall(hsWindow.subrole, hsWindow) or ''

  -- Check title requirements
  if config.requireTitle and #title == 0 then
    return false, 'empty title'
  end

  if config.minTitleLength and config.minTitleLength > 0 then
    if #title < config.minTitleLength then
      return false, 'title too short'
    end
  end

  -- Check role requirements
  if config.requireRole and #role == 0 then
    return false, 'empty role'
  end

  if config.allowedRoles then
    if type(config.allowedRoles) == 'table' then
      if not config.allowedRoles[role] then
        return false, 'role not allowed'
      end
    end
  end

  return true, nil
end

--- Create a default PreFilter configuration.
--- @return table Default config
function PreFilter.defaultConfig()
  return {
    ignoreBundleIDs = {},
    ignoreAppNames = {},
    ignoreAppPattern = '^QTKitServer%-',  -- Default pattern from current impl
    requireTitle = false,
    requireRole = false,
    minTitleLength = 0,
    allowedRoles = nil,
  }
end

-- Expose for testing
windowfilter._PreFilter = PreFilter

----------------------------------------------------------------------
-- SECTION 8: PLACEHOLDER FOR FUTURE COMPONENTS
----------------------------------------------------------------------
-- Components will be added in subsequent steps:
-- Step 5: Events, Subscriptions
-- Step 6: Tracker
-- Step 7: Manager
-- Step 8: WindowFilter class (public API)
-- Step 9: Default filters, module functions

----------------------------------------------------------------------
-- RETURN MODULE
----------------------------------------------------------------------

return windowfilter
