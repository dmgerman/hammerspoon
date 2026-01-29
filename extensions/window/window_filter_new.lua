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
-- SECTION 8: EVENTS AND SUBSCRIPTIONS
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Event Constants
----------------------------------------------------------------------
-- All events that can be subscribed to via windowfilter:subscribe().
-- These match the current implementation exactly for API compatibility.

--- Event: a new window was created
windowfilter.windowCreated = 'windowCreated'

--- Event: a window was destroyed
windowfilter.windowDestroyed = 'windowDestroyed'

--- Event: a window was moved or resized, including toggling fullscreen/maximize
windowfilter.windowMoved = 'windowMoved'

--- Event: a window was expanded to fullscreen
windowfilter.windowFullscreened = 'windowFullscreened'

--- Event: a window was reverted back from fullscreen
windowfilter.windowUnfullscreened = 'windowUnfullscreened'

--- Event: a window was minimized
windowfilter.windowMinimized = 'windowMinimized'

--- Event: a window was unminimized
windowfilter.windowUnminimized = 'windowUnminimized'

--- Event: a window was unhidden (app was unhidden via cmd-h)
windowfilter.windowUnhidden = 'windowUnhidden'

--- Event: a window was hidden (app was hidden via cmd-h)
windowfilter.windowHidden = 'windowHidden'

--- Event: a window became visible (in any Mission Control Space)
windowfilter.windowVisible = 'windowVisible'

--- Event: a window is no longer visible (in any Mission Control Space)
windowfilter.windowNotVisible = 'windowNotVisible'

--- Event: a window is now in the current Mission Control Space
windowfilter.windowInCurrentSpace = 'windowInCurrentSpace'

--- Event: a window is no longer in the current Mission Control Space
windowfilter.windowNotInCurrentSpace = 'windowNotInCurrentSpace'

--- Event: a window became actually visible on screen
windowfilter.windowOnScreen = 'windowOnScreen'

--- Event: a window is no longer actually visible on any screen
windowfilter.windowNotOnScreen = 'windowNotOnScreen'

--- Event: a window received focus
windowfilter.windowFocused = 'windowFocused'

--- Event: a window lost focus
windowfilter.windowUnfocused = 'windowUnfocused'

--- Event: a window's title changed
windowfilter.windowTitleChanged = 'windowTitleChanged'

--- Pseudo-event: a previously rejected window is now allowed
--- Emitted before the actual event that caused the window to be allowed
windowfilter.windowAllowed = 'windowAllowed'

--- Pseudo-event: a previously allowed window is now rejected
--- Emitted after the actual event that caused the window to be rejected
windowfilter.windowRejected = 'windowRejected'

--- Pseudo-event: the windowfilter now allows one window (was empty before)
--- Emitted after the actual event that caused a window to be allowed
windowfilter.hasWindow = 'hasWindow'

--- Pseudo-event: the windowfilter now rejects all windows (was non-empty before)
--- Emitted after the actual event that caused the last window to be rejected
windowfilter.hasNoWindows = 'hasNoWindows'

--- Pseudo-event: the list of allowed windows has changed
windowfilter.windowsChanged = 'windowsChanged'

-- Set of all valid events for validation
local validEvents = {
  [windowfilter.windowCreated] = true,
  [windowfilter.windowDestroyed] = true,
  [windowfilter.windowMoved] = true,
  [windowfilter.windowFullscreened] = true,
  [windowfilter.windowUnfullscreened] = true,
  [windowfilter.windowMinimized] = true,
  [windowfilter.windowUnminimized] = true,
  [windowfilter.windowUnhidden] = true,
  [windowfilter.windowHidden] = true,
  [windowfilter.windowVisible] = true,
  [windowfilter.windowNotVisible] = true,
  [windowfilter.windowInCurrentSpace] = true,
  [windowfilter.windowNotInCurrentSpace] = true,
  [windowfilter.windowOnScreen] = true,
  [windowfilter.windowNotOnScreen] = true,
  [windowfilter.windowFocused] = true,
  [windowfilter.windowUnfocused] = true,
  [windowfilter.windowTitleChanged] = true,
  [windowfilter.windowAllowed] = true,
  [windowfilter.windowRejected] = true,
  [windowfilter.hasWindow] = true,
  [windowfilter.hasNoWindows] = true,
  [windowfilter.windowsChanged] = true,
}

--- Check if an event name is valid.
--- @param event string The event name to check
--- @return boolean true if valid
local function isValidEvent(event)
  return validEvents[event] == true
end

-- Expose for testing
windowfilter._validEvents = validEvents
windowfilter._isValidEvent = isValidEvent

----------------------------------------------------------------------
-- Sort Order Constants
----------------------------------------------------------------------
-- Constants for getWindows() sort order parameter.

--- Sort by focus time, most recently focused first
windowfilter.sortByFocusedLast = 'focusedLast'

--- Sort by focus time, least recently focused first
windowfilter.sortByFocused = 'focused'

--- Sort by creation time, most recently created first
windowfilter.sortByCreatedLast = 'createdLast'

--- Sort by creation time, oldest first
windowfilter.sortByCreated = 'created'

----------------------------------------------------------------------
-- Subscriptions: Callback storage and emission
----------------------------------------------------------------------
-- Manages event subscriptions for a single windowfilter instance.
-- Callbacks are stored as sets per event for O(1) add/remove.
-- Emission uses pcall to protect against callback errors.

local Subscriptions = {}
Subscriptions.__index = Subscriptions

--- Create a new Subscriptions object.
--- @return table Subscriptions object
function Subscriptions.new()
  local self = setmetatable({}, Subscriptions)
  self.callbacks = {}  -- event -> { [fn] = true }
  return self
end

--- Add a callback for an event.
--- @param event string The event name (must be a valid event constant)
--- @param fn function The callback function
--- @return boolean true if added, false if already existed
function Subscriptions:add(event, fn)
  -- Validate event
  if not isValidEvent(event) then
    error(sformat('invalid event: %s', tostring(event)), 2)
  end
  -- Validate callback
  if type(fn) ~= 'function' then
    error(sformat('callback must be a function, got %s', type(fn)), 2)
  end

  -- Create event table if needed
  if not self.callbacks[event] then
    self.callbacks[event] = {}
  end

  -- Check for duplicate
  if self.callbacks[event][fn] then
    return false
  end

  self.callbacks[event][fn] = true
  return true
end

--- Remove a callback for an event.
--- @param event string The event name
--- @param fn function The callback function to remove
--- @return boolean true if removed, false if not found
function Subscriptions:remove(event, fn)
  if not self.callbacks[event] then
    return false
  end

  if not self.callbacks[event][fn] then
    return false
  end

  self.callbacks[event][fn] = nil

  -- Clean up empty event table
  if not next(self.callbacks[event]) then
    self.callbacks[event] = nil
  end

  return true
end

--- Remove all callbacks for a specific event, or all callbacks if event is nil.
--- @param event string|nil The event name, or nil to remove all
--- @return number The number of callbacks removed
function Subscriptions:removeAll(event)
  local count = 0

  if event then
    -- Remove all for specific event
    if self.callbacks[event] then
      for _ in pairs(self.callbacks[event]) do
        count = count + 1
      end
      self.callbacks[event] = nil
    end
  else
    -- Remove all callbacks
    for ev, fns in pairs(self.callbacks) do
      for _ in pairs(fns) do
        count = count + 1
      end
    end
    self.callbacks = {}
  end

  return count
end

--- Emit an event to all subscribed callbacks.
--- Callbacks receive (window, appName, event) as arguments.
--- Errors in callbacks are caught and logged, but don't stop other callbacks.
--- @param event string The event name
--- @param window userdata The hs.window object
--- @param appName string The application name
--- @return number The number of callbacks called
function Subscriptions:emit(event, window, appName)
  local fns = self.callbacks[event]
  if not fns then return 0 end

  local count = 0

  -- Iterate over a snapshot of callbacks to handle removal during emit
  local callbackList = {}
  for fn in pairs(fns) do
    tinsert(callbackList, fn)
  end

  for _, fn in ipairs(callbackList) do
    -- Only call if still subscribed (might have been removed by earlier callback)
    if fns[fn] then
      local ok, err = pcall(fn, window, appName, event)
      if not ok then
        print(sformat('[wfilter] callback error for %s: %s', event, tostring(err)))
      end
      count = count + 1
    end
  end

  return count
end

--- Check if there are any callbacks registered.
--- @return boolean true if at least one callback exists
function Subscriptions:hasAny()
  return next(self.callbacks) ~= nil
end

--- Check if there are callbacks for a specific event.
--- @param event string The event name
--- @return boolean true if callbacks exist for this event
function Subscriptions:hasEvent(event)
  return self.callbacks[event] ~= nil and next(self.callbacks[event]) ~= nil
end

--- Get the count of callbacks for an event, or total if event is nil.
--- @param event string|nil The event name, or nil for total count
--- @return number The callback count
function Subscriptions:count(event)
  if event then
    if not self.callbacks[event] then return 0 end
    local n = 0
    for _ in pairs(self.callbacks[event]) do n = n + 1 end
    return n
  else
    local n = 0
    for _, fns in pairs(self.callbacks) do
      for _ in pairs(fns) do n = n + 1 end
    end
    return n
  end
end

--- String representation for debugging.
function Subscriptions:__tostring()
  local eventCount = 0
  local totalCallbacks = 0
  for _, fns in pairs(self.callbacks) do
    eventCount = eventCount + 1
    for _ in pairs(fns) do totalCallbacks = totalCallbacks + 1 end
  end
  return sformat('Subscriptions: %d events, %d callbacks', eventCount, totalCallbacks)
end

-- Expose for testing
windowfilter._Subscriptions = Subscriptions

----------------------------------------------------------------------
-- SECTION 9: TRACKER
----------------------------------------------------------------------
-- Tracker manages watchers for apps and windows, reporting raw events
-- to the Manager. It handles:
-- - App lifecycle (launched, terminated, activated, deactivated, hidden, unhidden)
-- - Window lifecycle (created, destroyed, moved, minimized, etc.)
-- - Retry logic for apps/windows that aren't ready yet
-- - Debouncing for move/title events
-- - Zombie cleanup

-- UI element watcher event constants (from hs.uielement.watcher)
local uiwatcher = hs.uielement.watcher

-- Application watcher event constants (from hs.application.watcher)
local appwatcher = hs.application.watcher

----------------------------------------------------------------------
-- ManagerStub: Minimal stub for testing Tracker in isolation
----------------------------------------------------------------------
-- Implements the Manager interface with logging/counting for tests.
-- Real Manager (Step 7) will replace this.

local ManagerStub = {}
ManagerStub.__index = ManagerStub

function ManagerStub.new()
  local self = setmetatable({}, ManagerStub)
  self.events = {}  -- List of {event, args} for verification
  self.preFilter = PreFilter.defaultConfig()
  return self
end

function ManagerStub:_record(event, ...)
  table.insert(self.events, {event = event, args = {...}})
end

function ManagerStub:onWindowCreated(windowInfo, appInfo)
  self:_record('windowCreated', windowInfo, appInfo)
end

function ManagerStub:onWindowDestroyed(windowInfo, appInfo)
  self:_record('windowDestroyed', windowInfo, appInfo)
end

function ManagerStub:onWindowMoved(windowInfo, appInfo)
  self:_record('windowMoved', windowInfo, appInfo)
end

function ManagerStub:onWindowMinimized(windowInfo, appInfo)
  self:_record('windowMinimized', windowInfo, appInfo)
end

function ManagerStub:onWindowUnminimized(windowInfo, appInfo)
  self:_record('windowUnminimized', windowInfo, appInfo)
end

function ManagerStub:onWindowTitleChanged(windowInfo, appInfo)
  self:_record('windowTitleChanged', windowInfo, appInfo)
end

function ManagerStub:onAppActivated(appInfo)
  self:_record('appActivated', appInfo)
end

function ManagerStub:onAppDeactivated(appInfo)
  self:_record('appDeactivated', appInfo)
end

function ManagerStub:onAppHidden(appInfo)
  self:_record('appHidden', appInfo)
end

function ManagerStub:onAppUnhidden(appInfo)
  self:_record('appUnhidden', appInfo)
end

function ManagerStub:onFocusChanged(windowInfo, appInfo, prevWindowInfo)
  self:_record('focusChanged', windowInfo, appInfo, prevWindowInfo)
end

function ManagerStub:getEventCount(eventName)
  local count = 0
  for _, e in ipairs(self.events) do
    if e.event == eventName then count = count + 1 end
  end
  return count
end

function ManagerStub:getLastEvent(eventName)
  for i = #self.events, 1, -1 do
    if self.events[i].event == eventName then
      return self.events[i]
    end
  end
  return nil
end

function ManagerStub:clearEvents()
  self.events = {}
end

-- Expose for testing
windowfilter._ManagerStub = ManagerStub

----------------------------------------------------------------------
-- Tracker: Manages watchers and reports events to Manager
----------------------------------------------------------------------

local Tracker = {}
Tracker.__index = Tracker

--- Create a new Tracker.
--- @param manager table Object implementing Manager interface
--- @return table Tracker instance
function Tracker.new(manager)
  local self = setmetatable({}, Tracker)

  self.manager = manager
  self.apps = {}              -- pid -> AppInfo
  self.appWatcher = nil       -- hs.application.watcher
  self.pendingApps = {}       -- pid -> {timer, retryCount}
  self.pendingWindows = {}    -- window userdata -> {timer, retryCount, appInfo}
  self.movedTimers = {}       -- windowId -> timer (debounce)
  self.titleTimers = {}       -- windowId -> timer (debounce)
  self.running = false
  self.focusedWindowId = nil  -- Track for focus change detection
  self.focusedAppPid = nil

  return self
end

--- Start tracking apps and windows.
function Tracker:start()
  if self.running then return end
  self.running = true

  -- Create app watcher
  self.appWatcher = hs.application.watcher.new(function(name, event, app)
    self:_onAppEvent(name, event, app)
  end)

  -- Register existing apps
  local runningApps = hs.application.runningApplications()
  for _, app in ipairs(runningApps) do
    self:registerApp(app)
  end

  -- Start watching for new apps
  self.appWatcher:start()

  print('[wfilter] Tracker started')
end

--- Stop tracking and clean up all watchers.
function Tracker:stop()
  if not self.running then return end
  self.running = false

  -- Stop app watcher
  if self.appWatcher then
    self.appWatcher:stop()
    self.appWatcher = nil
  end

  -- Unregister all apps (stops their watchers)
  for pid, _ in pairs(self.apps) do
    self:unregisterApp(pid)
  end

  -- Cancel pending app timers
  for pid, pending in pairs(self.pendingApps) do
    if pending.timer then pending.timer:stop() end
  end
  self.pendingApps = {}

  -- Cancel pending window timers
  for win, pending in pairs(self.pendingWindows) do
    if pending.timer then pending.timer:stop() end
  end
  self.pendingWindows = {}

  -- Cancel debounce timers
  for id, timer in pairs(self.movedTimers) do
    timer:stop()
  end
  self.movedTimers = {}

  for id, timer in pairs(self.titleTimers) do
    timer:stop()
  end
  self.titleTimers = {}

  self.focusedWindowId = nil
  self.focusedAppPid = nil

  print('[wfilter] Tracker stopped')
end

--- Get preFilter config from manager or use default.
--- @return table PreFilter config
function Tracker:_getPreFilterConfig()
  if self.manager and self.manager.preFilter then
    return self.manager.preFilter
  end
  return PreFilter.defaultConfig()
end

--- Safely call a Manager callback, catching errors.
--- @param method string Method name
--- @param ... any Arguments to pass
function Tracker:_notifyManager(method, ...)
  if not self.manager then return end
  local fn = self.manager[method]
  if not fn then return end

  local ok, err = pcall(fn, self.manager, ...)
  if not ok then
    print(sformat('[wfilter] Manager.%s error: %s', method, tostring(err)))
  end
end

--- Register an app for tracking.
--- @param hsApp userdata The hs.application object
--- @param retryCount number Optional retry count
function Tracker:registerApp(hsApp, retryCount)
  if not self.running then return end
  if not hsApp then return end

  local pid = safeCall(hsApp.pid, hsApp)
  if not pid then return end

  -- Already registered?
  if self.apps[pid] then return end

  -- Cancel any pending retry for this app
  if self.pendingApps[pid] then
    if self.pendingApps[pid].timer then
      self.pendingApps[pid].timer:stop()
    end
    self.pendingApps[pid] = nil
  end

  -- PreFilter check
  local config = self:_getPreFilterConfig()
  local shouldTrack, reason = PreFilter.shouldTrackApp(hsApp, config)
  if not shouldTrack then
    return
  end

  retryCount = (retryCount or 0) + 1

  -- Check if app is ready (can get focused window)
  -- Some apps take time to initialize their accessibility features
  local fw = safeCall(hsApp.focusedWindow, hsApp)

  if fw or retryCount > Config.MAX_RETRIES then
    -- Create AppInfo
    local appInfo = AppInfo.new(hsApp, pid)
    if not appInfo then return end

    self.apps[pid] = appInfo

    -- Create watcher for this app's UI events
    -- Note: watcher APIs must be called directly, not through safeCall
    local ok, watcher = pcall(function()
      return hsApp:newWatcher(function(element, event, watcherObj, name)
        self:_onAppUIEvent(element, event, pid, name)
      end)
    end)

    if ok and watcher then
      appInfo.watcher = watcher
      -- Watch for new windows and focus changes
      local startOk = pcall(function()
        watcher:start({
          uiwatcher.windowCreated,
          uiwatcher.focusedWindowChanged,
        })
      end)
      if not startOk then
        print(sformat('[wfilter] Failed to start watcher for %s', appInfo.name))
      end
    end

    -- Register existing windows
    self:_registerAppWindows(appInfo)

  else
    -- App not ready, retry later
    local delay = retryCount * Config.RETRY_DELAY
    self.pendingApps[pid] = {
      retryCount = retryCount,
      timer = hs.timer.doAfter(delay, function()
        self.pendingApps[pid] = nil
        self:registerApp(hsApp, retryCount)
      end)
    }
  end
end

--- Register all windows for an app.
--- @param appInfo table AppInfo object
function Tracker:_registerAppWindows(appInfo)
  if not appInfo or not appInfo._app then return end

  local windows = safeCall(appInfo._app.allWindows, appInfo._app)
  if not windows then return end

  for _, hsWindow in ipairs(windows) do
    self:registerWindow(hsWindow, appInfo)
  end
end

--- Register a window for tracking.
--- @param hsWindow userdata The hs.window object
--- @param appInfo table The AppInfo for this window's app
--- @param retryCount number Optional retry count
function Tracker:registerWindow(hsWindow, appInfo, retryCount)
  if not self.running then return end
  if not hsWindow or not appInfo then return end

  local id = safeCall(hsWindow.id, hsWindow)

  if not id then
    -- Window doesn't have ID yet, retry later
    retryCount = (retryCount or 0) + 1
    if retryCount <= Config.MAX_RETRIES then
      local delay = retryCount * Config.RETRY_DELAY
      self.pendingWindows[hsWindow] = {
        retryCount = retryCount,
        appInfo = appInfo,
        timer = hs.timer.doAfter(delay, function()
          self.pendingWindows[hsWindow] = nil
          self:registerWindow(hsWindow, appInfo, retryCount)
        end)
      }
    end
    return
  end

  -- Cancel any pending retry
  if self.pendingWindows[hsWindow] then
    if self.pendingWindows[hsWindow].timer then
      self.pendingWindows[hsWindow].timer:stop()
    end
    self.pendingWindows[hsWindow] = nil
  end

  -- Already registered?
  if appInfo.windows[id] then return end

  -- PreFilter check
  local config = self:_getPreFilterConfig()
  local shouldTrack, reason = PreFilter.shouldTrack(hsWindow, appInfo._app, config)
  if not shouldTrack then
    return
  end

  -- Create WindowInfo
  local windowInfo = WindowInfo.new(hsWindow)
  if not windowInfo then return end

  -- Set app reference
  windowInfo.appName = appInfo.name
  windowInfo.appPid = appInfo.pid

  -- Create watcher for this window's UI events
  -- Note: watcher APIs must be called directly, not through safeCall
  local ok, watcher = pcall(function()
    return hsWindow:newWatcher(function(element, event, watcherObj, name)
      self:_onWindowEvent(event, appInfo.pid, id)
    end)
  end)

  if ok and watcher then
    windowInfo.watcher = watcher
    local startOk = pcall(function()
      watcher:start({
        uiwatcher.elementDestroyed,
        uiwatcher.windowMoved,
        uiwatcher.windowResized,
        uiwatcher.windowMinimized,
        uiwatcher.windowUnminimized,
        uiwatcher.titleChanged,
      })
    end)
    if not startOk then
      print(sformat('[wfilter] Failed to start window watcher for %s (%d)', appInfo.name, id))
    end
  end

  -- Store window
  appInfo.windows[id] = windowInfo

  -- Notify manager
  self:_notifyManager('onWindowCreated', windowInfo, appInfo)
end

--- Unregister a window.
--- @param windowInfo table WindowInfo object
--- @param appInfo table AppInfo object
function Tracker:unregisterWindow(windowInfo, appInfo)
  if not windowInfo or not appInfo then return end

  local id = windowInfo.id

  -- Stop window watcher
  if windowInfo.watcher then
    safeCall(windowInfo.watcher.stop, windowInfo.watcher)
    windowInfo.watcher = nil
  end

  -- Cancel debounce timers for this window
  if self.movedTimers[id] then
    self.movedTimers[id]:stop()
    self.movedTimers[id] = nil
  end
  if self.titleTimers[id] then
    self.titleTimers[id]:stop()
    self.titleTimers[id] = nil
  end

  -- Remove from app
  appInfo.windows[id] = nil

  -- Clear focus if this was focused
  if self.focusedWindowId == id then
    self.focusedWindowId = nil
  end

  -- Notify manager
  self:_notifyManager('onWindowDestroyed', windowInfo, appInfo)
end

--- Unregister an app and all its windows.
--- @param pid number Process ID
function Tracker:unregisterApp(pid)
  local appInfo = self.apps[pid]
  if not appInfo then return end

  -- Unregister all windows first
  for id, windowInfo in pairs(appInfo.windows) do
    self:unregisterWindow(windowInfo, appInfo)
  end

  -- Stop app watcher
  if appInfo.watcher then
    safeCall(appInfo.watcher.stop, appInfo.watcher)
    appInfo.watcher = nil
  end

  -- Remove from tracked apps
  self.apps[pid] = nil

  -- Clear focus if this was the focused app
  if self.focusedAppPid == pid then
    self.focusedAppPid = nil
  end
end

--- Handle app watcher events.
--- @param name string App name
--- @param event number Event type
--- @param hsApp userdata hs.application object
function Tracker:_onAppEvent(name, event, hsApp)
  if not self.running then return end
  if not name then return end

  local pid = hsApp and safeCall(hsApp.pid, hsApp)

  if event == appwatcher.launched then
    self:registerApp(hsApp)

  elseif event == appwatcher.terminated then
    if pid then
      -- Cancel any pending retry
      if self.pendingApps[pid] then
        if self.pendingApps[pid].timer then
          self.pendingApps[pid].timer:stop()
        end
        self.pendingApps[pid] = nil
      end
      self:unregisterApp(pid)
    end

  elseif event == appwatcher.activated then
    if pid then
      local appInfo = self.apps[pid]
      if appInfo then
        local prevPid = self.focusedAppPid
        self.focusedAppPid = pid
        appInfo:refresh()
        self:_notifyManager('onAppActivated', appInfo)
      else
        -- App activated but not registered yet, register it
        self:registerApp(hsApp)
      end
    end

  elseif event == appwatcher.deactivated then
    if pid then
      local appInfo = self.apps[pid]
      if appInfo then
        appInfo:refresh()
        self:_notifyManager('onAppDeactivated', appInfo)
      end
    end

  elseif event == appwatcher.hidden then
    if pid then
      local appInfo = self.apps[pid]
      if appInfo then
        appInfo.isHidden = true
        self:_notifyManager('onAppHidden', appInfo)
      end
    end

  elseif event == appwatcher.unhidden then
    if pid then
      local appInfo = self.apps[pid]
      if appInfo then
        appInfo.isHidden = false
        self:_notifyManager('onAppUnhidden', appInfo)
      end
    end
  end
end

--- Handle per-app UI events (windowCreated, focusedWindowChanged).
--- @param element userdata UI element
--- @param event number Event type
--- @param pid number Process ID
--- @param name string App name
function Tracker:_onAppUIEvent(element, event, pid, name)
  if not self.running then return end

  local appInfo = self.apps[pid]
  if not appInfo then return end

  if event == uiwatcher.windowCreated then
    -- element is the new window
    if element then
      self:registerWindow(element, appInfo)
    end

  elseif event == uiwatcher.focusedWindowChanged then
    -- element is the newly focused window
    if element then
      local id = safeCall(element.id, element)
      if id and id ~= self.focusedWindowId then
        local prevWindowInfo = nil
        if self.focusedWindowId then
          -- Find previous focused window
          for _, info in pairs(appInfo.windows) do
            if info.id == self.focusedWindowId then
              prevWindowInfo = info
              break
            end
          end
        end

        self.focusedWindowId = id

        -- Get or create WindowInfo for the focused window
        local windowInfo = appInfo.windows[id]
        if not windowInfo then
          -- Window not registered yet, register it
          self:registerWindow(element, appInfo)
          windowInfo = appInfo.windows[id]
        end

        if windowInfo then
          windowInfo.timeFocused = hs.timer.absoluteTime()
          self:_notifyManager('onFocusChanged', windowInfo, appInfo, prevWindowInfo)
        end
      end
    end
  end
end

--- Handle per-window UI events.
--- @param event number Event type
--- @param pid number Process ID
--- @param windowId number Window ID
function Tracker:_onWindowEvent(event, pid, windowId)
  if not self.running then return end

  local appInfo = self.apps[pid]
  if not appInfo then return end

  local windowInfo = appInfo.windows[windowId]
  if not windowInfo then return end

  if event == uiwatcher.elementDestroyed then
    self:unregisterWindow(windowInfo, appInfo)

  elseif event == uiwatcher.windowMoved or event == uiwatcher.windowResized then
    -- Debounce move/resize events
    if self.movedTimers[windowId] then
      self.movedTimers[windowId]:stop()
    end
    self.movedTimers[windowId] = hs.timer.doAfter(Config.MOVED_DEBOUNCE, function()
      self.movedTimers[windowId] = nil
      if not self.running then return end
      if not appInfo.windows[windowId] then return end

      -- Refresh and notify
      windowInfo:refresh()
      self:_notifyManager('onWindowMoved', windowInfo, appInfo)
    end)

  elseif event == uiwatcher.windowMinimized then
    windowInfo.isMinimized = true
    windowInfo.isVisible = false
    self:_notifyManager('onWindowMinimized', windowInfo, appInfo)

  elseif event == uiwatcher.windowUnminimized then
    windowInfo.isMinimized = false
    windowInfo:refresh()  -- Get current visibility
    self:_notifyManager('onWindowUnminimized', windowInfo, appInfo)

  elseif event == uiwatcher.titleChanged then
    -- Debounce title change events
    if self.titleTimers[windowId] then
      self.titleTimers[windowId]:stop()
    end
    self.titleTimers[windowId] = hs.timer.doAfter(Config.TITLE_DEBOUNCE, function()
      self.titleTimers[windowId] = nil
      if not self.running then return end
      if not appInfo.windows[windowId] then return end

      -- Refresh and notify
      local oldTitle = windowInfo.title
      windowInfo:refresh()
      if windowInfo.title ~= oldTitle then
        self:_notifyManager('onWindowTitleChanged', windowInfo, appInfo)
      end
    end)
  end
end

--- Clean up zombie apps (apps that terminated without notification).
function Tracker:cleanupZombies()
  if not self.running then return end

  for pid, appInfo in pairs(self.apps) do
    local app = hs.application.applicationForPID(pid)
    if not app then
      print(sformat('[wfilter] Cleaning up zombie app: %s (%d)', appInfo.name, pid))
      self:unregisterApp(pid)
    end
  end
end

--- Get count of tracked apps.
--- @return number
function Tracker:getAppCount()
  local count = 0
  for _ in pairs(self.apps) do count = count + 1 end
  return count
end

--- Get count of tracked windows.
--- @return number
function Tracker:getWindowCount()
  local count = 0
  for _, appInfo in pairs(self.apps) do
    for _ in pairs(appInfo.windows) do count = count + 1 end
  end
  return count
end

--- String representation for debugging.
function Tracker:__tostring()
  return sformat('Tracker: %d apps, %d windows, running=%s',
    self:getAppCount(), self:getWindowCount(), tostring(self.running))
end

-- Expose for testing
windowfilter._Tracker = Tracker

----------------------------------------------------------------------
-- SECTION 10: PLACEHOLDER FOR FUTURE COMPONENTS
----------------------------------------------------------------------
-- Components will be added in subsequent steps:
-- Step 7: Manager
-- Step 8: WindowFilter class (public API)
-- Step 9: Default filters, module functions

----------------------------------------------------------------------
-- RETURN MODULE
----------------------------------------------------------------------

return windowfilter
