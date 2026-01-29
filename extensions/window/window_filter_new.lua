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

-- hs.* caching for dofile() compatibility
local timer = hs.timer

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
  local allowedRoles = rule.allowRoles or windowfilter.allowedWindowRoles or Config.ALLOWED_ROLES
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

----------------------------------------------------------------------
-- Filter Instance Methods
----------------------------------------------------------------------
-- These methods allow Filter to be used as an instance with stored rules.

-- Save reference to the static matches function before we shadow it
local Filter_matchesStatic = Filter.matches

Filter.__index = Filter

--- Create a new Filter instance.
--- @return table Filter instance with empty rules
function Filter.new()
  local self = setmetatable({}, Filter)
  self._rules = FilterRules.new()
  return self
end

--- Set filter rules for a specific app.
--- @param appName string Application name
--- @param rules boolean|table Filter rules (true=allow, false=reject, table=detailed rules)
function Filter:setAppFilter(appName, rules)
  if type(rules) == 'boolean' then
    self._rules.appRules[appName] = rules
  elseif type(rules) == 'table' then
    self._rules.appRules[appName] = rules
  else
    self._rules.appRules[appName] = nil
  end
end

--- Set the default filter for apps without specific rules.
--- @param rules boolean|table Filter rules
function Filter:setDefaultFilter(rules)
  if rules == true then
    self._rules.default = {}  -- Empty table means "allow with no restrictions"
  elseif rules == false then
    self._rules.default = false
  elseif type(rules) == 'table' then
    self._rules.default = rules
  else
    self._rules.default = nil
  end
end

--- Set the override filter that applies to all windows.
--- @param rules boolean|table Filter rules
function Filter:setOverrideFilter(rules)
  if rules == true then
    self._rules.override = {}  -- Allow all
  elseif rules == false then
    self._rules.override = false
  elseif type(rules) == 'table' then
    self._rules.override = rules
  else
    self._rules.override = nil
  end
end

--- Get current filter configuration.
--- @return table Filter rules
function Filter:getFilters()
  local result = {}
  if self._rules.default ~= nil then
    result.default = self._rules.default
  end
  if self._rules.override ~= nil then
    result.override = self._rules.override
  end
  for appName, rules in pairs(self._rules.appRules) do
    result[appName] = rules
  end
  return result
end

--- Check if an app is allowed by this filter.
--- @param appName string Application name
--- @return boolean
function Filter:isAppAllowed(appName)
  -- Check if app is explicitly rejected
  if self._rules.appRules[appName] == false then
    return false
  end
  -- Check if app has rules (meaning it's allowed)
  if self._rules.appRules[appName] then
    return true
  end
  -- Check default
  if self._rules.default == false then
    return false
  end
  -- Default allows
  return true
end

--- Match a window against this filter's rules (instance method).
--- @param windowInfo table WindowInfo object
--- @param appInfo table|nil AppInfo object
--- @param context table {focusedWindowId, activeAppPid}
--- @return boolean allowed
function Filter:matchWindow(windowInfo, appInfo, context)
  local ok, _ = Filter_matchesStatic(self._rules, windowInfo, context)
  return ok
end

--- Create a copy of this filter.
--- @return table New Filter with same rules
function Filter:copy()
  local new = Filter.new()
  new._rules.default = self._rules.default
  new._rules.override = self._rules.override
  for appName, rules in pairs(self._rules.appRules) do
    if type(rules) == 'table' then
      -- Deep copy rule table
      local copy = {}
      for k, v in pairs(rules) do copy[k] = v end
      new._rules.appRules[appName] = copy
    else
      new._rules.appRules[appName] = rules
    end
  end
  return new
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

----------------------------------------------------------------------
-- Ignore Lists (matching original implementation)
----------------------------------------------------------------------

-- Apps that have no windows or GUI, such as system services, background daemons, and helper apps
-- These are always ignored even by an "allow all" windowfilter
local SKIP_APPS_NO_PID = {
  -- These will be shown as a warning in the console ("No accessibility access to app ...")
  'universalaccessd', 'sharingd', 'Safari Networking', 'Spotlight Networking',
  'iTunes Helper', 'Safari Web Content', 'App Store Web Content', 'Safari Database Storage',
  'Google Chrome Helper', 'Spotify Helper', 'Todoist Networking', 'Safari Storage',
  'Todoist Database Storage', 'AAM Updates Notifier', 'Slack Helper',
}

local SKIP_APPS_NO_WINDOWS = {
  -- Apps with no useful windows
  'com.apple.internetaccounts', 'CoreServicesUIAgent', 'AirPlayUIAgent',
  'com.apple.security.pboxd', 'PowerChime', 'SystemUIServer', 'Dock',
  'com.apple.dock.extra', 'storeuid', 'Folder Actions Dispatcher',
  'Keychain Circle Notification', 'Wi-Fi', 'Image Capture Extension',
  'iCloud Photos', 'System Events', 'Speech Synthesis Server',
  'Dropbox Finder Integration', 'LaterAgent', 'Karabiner_AXNotifier',
  'Photos Agent', 'EscrowSecurityAlert', 'Google Chrome Helper',
  'com.apple.MailServiceAgent', 'Safari Web Content', 'Mail Web Content',
  'Safari Networking', 'nbagent', 'rcd', 'Evernote Helper', 'BTTRelaunch',
}

-- Apps with transient windows that are usually not interesting for window management
local SKIP_APPS_TRANSIENT_WINDOWS = {
  -- System UI
  'Spotlight', 'Notification Center', 'loginwindow', 'ScreenSaverEngine', 'PressAndHold',
  -- Preferences/utilities
  'PopClip', 'Isolator', 'CheatSheet', 'CornerClickBG', 'Alfred 2', 'Moom', 'CursorSense Manager',
  -- Menubar apps
  'Music Manager', 'Google Drive', 'Dropbox', '1Password mini', 'Colors for Hue', 'MacID',
  'CrashPlan menu bar', 'Flux', 'Jettison', 'Bartender', 'SystemPal', 'BetterSnapTool',
  'Grandview', 'Radium', 'MenuMetersApp', 'DemoPro',
}

-- Build the ignoreAlways table (apps always ignored)
local ignoreAlways = {}
for _, list in ipairs({SKIP_APPS_NO_PID, SKIP_APPS_NO_WINDOWS}) do
  for _, appname in ipairs(list) do
    ignoreAlways[appname] = true
  end
end

-- Build the ignoreInDefaultFilter table (apps ignored in default filter only)
local ignoreInDefaultFilter = {}
for _, appname in ipairs(SKIP_APPS_TRANSIENT_WINDOWS) do
  ignoreInDefaultFilter[appname] = true
end

--- hs.window.filter.ignoreAlways
--- Variable
--- A table of application names (as per `hs.application:name()`) that are always ignored by this module.
--- These are apps with no windows or any visible GUI, such as system services, background daemons and "helper" apps.
---
--- You can add an app to this table with `hs.window.filter.ignoreAlways['Background App Title'] = true`
---
--- Notes:
---  * As the name implies, even the empty, "allow all" windowfilter will ignore these apps.
---  * You don't *need* to keep this table up to date, since non GUI apps will simply never show up anywhere;
---    this table is just used as a "root" filter to gain a (very small) performance improvement.
windowfilter.ignoreAlways = ignoreAlways

--- hs.window.filter.ignoreInDefaultFilter
--- Variable
--- A table of application names that are ignored by the default windowfilter.
--- These are apps with transient windows that are usually not interesting for window management.
---
--- You can add an app to this table with `hs.window.filter.ignoreInDefaultFilter['Menubar App'] = true`
windowfilter.ignoreInDefaultFilter = ignoreInDefaultFilter

----------------------------------------------------------------------

--- Create a default PreFilter configuration.
--- Returns a fresh copy of the config to avoid shared state issues.
--- @return table Default config
function PreFilter.defaultConfig()
  -- Copy ignoreAlways to avoid shared state modification
  local ignoreAppNamesCopy = {}
  for k, v in pairs(ignoreAlways) do
    ignoreAppNamesCopy[k] = v
  end
  return {
    ignoreBundleIDs = {},
    ignoreAppNames = ignoreAppNamesCopy,  -- Use a copy, not a reference
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
-- SECTION 10: MANAGER
----------------------------------------------------------------------
-- Manager is a singleton that coordinates between Tracker and WindowFilter
-- instances. It handles:
-- - Tracker lifecycle (lazy start/stop)
-- - Instance registration (activate/deactivate)
-- - Event routing to active instances
-- - Spaces change handling
-- - Context access (focusedWindowId, activeAppPid)

local Manager = {}
Manager.__index = Manager

-- Singleton instance
local managerInstance = nil

--- Get the Manager singleton instance.
--- Creates it on first call.
--- @return table Manager instance
function Manager.getInstance()
  if not managerInstance then
    managerInstance = Manager._create()
  end
  return managerInstance
end

--- Create a new Manager instance (internal).
--- @return table Manager instance
function Manager._create()
  local self = setmetatable({}, Manager)

  self.tracker = nil              -- Tracker instance (created lazily)
  self.activeInstances = {}       -- {[wf] = true} active windowfilter instances
  self.spacesInstances = {}       -- {[wf] = true} instances that care about spaces
  self.spacesWatcher = nil        -- hs.spaces.watcher
  self.instanceCount = 0          -- Count of active instances
  self.preFilter = PreFilter.defaultConfig()  -- PreFilter config for Tracker

  return self
end

--- Activate a windowfilter instance.
--- Starts Tracker if this is the first active instance.
--- @param wf table WindowFilter instance
function Manager:activate(wf)
  if self.activeInstances[wf] then return end

  self.activeInstances[wf] = true
  self.instanceCount = self.instanceCount + 1

  -- Check if instance cares about spaces
  if wf._trackSpaces then
    self.spacesInstances[wf] = true
  end

  -- Start Tracker if first instance
  if self.instanceCount == 1 then
    self:_start()
  end

  -- Refresh the instance with current windows
  self:_refreshInstance(wf)
end

--- Deactivate a windowfilter instance.
--- Stops Tracker if this was the last active instance.
--- @param wf table WindowFilter instance
function Manager:deactivate(wf)
  if not self.activeInstances[wf] then return end

  self.activeInstances[wf] = nil
  self.spacesInstances[wf] = nil
  self.instanceCount = self.instanceCount - 1

  -- Stop Tracker if last instance
  if self.instanceCount == 0 then
    self:_stop()
  end
end

--- Get context for filter matching.
--- @return table {focusedWindowId, activeAppPid}
function Manager:getContext()
  if self.tracker then
    return {
      focusedWindowId = self.tracker.focusedWindowId,
      activeAppPid = self.tracker.focusedAppPid,
    }
  end
  return {focusedWindowId = nil, activeAppPid = nil}
end

--- Get the Tracker instance (for testing/debugging).
--- @return table|nil Tracker instance or nil if not started
function Manager:getTracker()
  return self.tracker
end

--- Check if Manager is running.
--- @return boolean
function Manager:isRunning()
  return self.tracker ~= nil and self.tracker.running
end

--- Get count of active instances.
--- @return number
function Manager:getInstanceCount()
  return self.instanceCount
end

--- Start the Manager (internal).
--- Creates and starts Tracker, starts spaces watcher.
function Manager:_start()
  if self.tracker then return end

  print('[wfilter] Manager starting')

  -- Create and start Tracker
  self.tracker = Tracker.new(self)
  self.tracker:start()

  -- Start spaces watcher
  self:_startSpacesWatcher()
end

--- Stop the Manager (internal).
--- Stops Tracker and spaces watcher.
function Manager:_stop()
  if not self.tracker then return end

  print('[wfilter] Manager stopping')

  -- Stop spaces watcher
  self:_stopSpacesWatcher()

  -- Stop and clear Tracker
  self.tracker:stop()
  self.tracker = nil
end

--- Start the spaces watcher (internal).
function Manager:_startSpacesWatcher()
  if self.spacesWatcher then return end

  self.spacesWatcher = hs.spaces.watcher.new(function()
    self:_onSpaceChanged()
  end)
  self.spacesWatcher:start()
end

--- Stop the spaces watcher (internal).
function Manager:_stopSpacesWatcher()
  if not self.spacesWatcher then return end

  self.spacesWatcher:stop()
  self.spacesWatcher = nil
end

--- Handle space change event (internal).
function Manager:_onSpaceChanged()
  -- Delay slightly to let the system settle
  hs.timer.doAfter(Config.SPACE_CHANGE_DELAY, function()
    self:_handleSpaceChange()
  end)
end

--- Process space change after delay (internal).
function Manager:_handleSpaceChange()
  if not self.tracker then return end

  print('[wfilter] Space changed, refreshing instances')

  -- Determine which instances to refresh
  local instancesToRefresh = {}

  -- Always refresh space-aware instances
  for wf in pairs(self.spacesInstances) do
    instancesToRefresh[wf] = true
  end

  -- Also refresh all active instances if forceRefreshOnSpaceChange
  if windowfilter.forceRefreshOnSpaceChange then
    for wf in pairs(self.activeInstances) do
      instancesToRefresh[wf] = true
    end
  end

  -- Notify each instance of space change
  for wf in pairs(instancesToRefresh) do
    self:_notifyInstance(wf, 'spaceChanged', nil, nil)
  end
end

--- Refresh a single instance with current windows (internal).
--- Called when instance is activated.
--- @param wf table WindowFilter instance
function Manager:_refreshInstance(wf)
  if not self.tracker then return end

  -- Send windowCreated for all currently tracked windows
  for _, appInfo in pairs(self.tracker.apps) do
    for _, windowInfo in pairs(appInfo.windows) do
      self:_notifyInstance(wf, 'windowCreated', windowInfo, appInfo)
    end
  end
end

--- Notify a single instance of an event (internal).
--- @param wf table WindowFilter instance
--- @param eventType string Event type name
--- @param windowInfo table|nil WindowInfo object
--- @param appInfo table|nil AppInfo object
function Manager:_notifyInstance(wf, eventType, windowInfo, appInfo)
  if not wf._handleTrackerEvent then return end

  local ok, err = pcall(wf._handleTrackerEvent, wf, eventType, windowInfo, appInfo)
  if not ok then
    print(sformat('[wfilter] Instance event handler error: %s', tostring(err)))
  end
end

--- Route an event to all active instances (internal).
--- @param eventType string Event type name
--- @param windowInfo table|nil WindowInfo object
--- @param appInfo table|nil AppInfo object
function Manager:_routeEvent(eventType, windowInfo, appInfo)
  for wf in pairs(self.activeInstances) do
    self:_notifyInstance(wf, eventType, windowInfo, appInfo)
  end
end

----------------------------------------------------------------------
-- Tracker callback interface implementation
-- These methods are called by Tracker and route to active instances
----------------------------------------------------------------------

function Manager:onWindowCreated(windowInfo, appInfo)
  self:_routeEvent('windowCreated', windowInfo, appInfo)
end

function Manager:onWindowDestroyed(windowInfo, appInfo)
  self:_routeEvent('windowDestroyed', windowInfo, appInfo)
end

function Manager:onWindowMoved(windowInfo, appInfo)
  self:_routeEvent('windowMoved', windowInfo, appInfo)
end

function Manager:onWindowMinimized(windowInfo, appInfo)
  self:_routeEvent('windowMinimized', windowInfo, appInfo)
end

function Manager:onWindowUnminimized(windowInfo, appInfo)
  self:_routeEvent('windowUnminimized', windowInfo, appInfo)
end

function Manager:onWindowTitleChanged(windowInfo, appInfo)
  self:_routeEvent('windowTitleChanged', windowInfo, appInfo)
end

function Manager:onAppActivated(appInfo)
  self:_routeEvent('appActivated', nil, appInfo)
end

function Manager:onAppDeactivated(appInfo)
  self:_routeEvent('appDeactivated', nil, appInfo)
end

function Manager:onAppHidden(appInfo)
  self:_routeEvent('appHidden', nil, appInfo)
end

function Manager:onAppUnhidden(appInfo)
  self:_routeEvent('appUnhidden', nil, appInfo)
end

function Manager:onFocusChanged(windowInfo, appInfo, prevWindowInfo)
  -- Route focus change with previous window info
  for wf in pairs(self.activeInstances) do
    if wf._handleFocusChanged then
      local ok, err = pcall(wf._handleFocusChanged, wf, windowInfo, appInfo, prevWindowInfo)
      if not ok then
        print(sformat('[wfilter] Instance focus handler error: %s', tostring(err)))
      end
    else
      -- Fall back to generic event
      self:_notifyInstance(wf, 'focusChanged', windowInfo, appInfo)
    end
  end
end

--- String representation for debugging.
function Manager:__tostring()
  return sformat('Manager: %d instances, running=%s',
    self.instanceCount, tostring(self:isRunning()))
end

-- Expose for testing
windowfilter._Manager = Manager

--- Module variable to control space change behavior.
--- If true, all active instances refresh on space change.
--- If false (default), only space-aware instances refresh.
windowfilter.forceRefreshOnSpaceChange = false

----------------------------------------------------------------------
-- SECTION 11: WINDOWFILTER CLASS (PUBLIC API)
----------------------------------------------------------------------
-- WindowFilter is the main public API. It provides:
-- - Filter configuration (setAppFilter, setDefaultFilter, etc.)
-- - Window queries (isAppAllowed, isWindowAllowed, getWindows)
-- - Event subscriptions (subscribe, unsubscribe)
-- - Lifecycle management (pause, resume, delete, keepActive)

local WindowFilter = {}
WindowFilter.__index = WindowFilter

-- Window state keys for tracking
local STATE_ALLOWED = 'allowed'
local STATE_VISIBLE = 'visible'
local STATE_ON_SCREEN = 'onScreen'
local STATE_IN_SPACE = 'inCurrentSpace'
local STATE_FOCUSED = 'focused'
local STATE_TIME_CREATED = 'timeCreated'
local STATE_TIME_FOCUSED = 'timeFocused'

----------------------------------------------------------------------
-- Constructor
----------------------------------------------------------------------

--- Create a new WindowFilter.
--- @param fn nil|boolean|string|table|function Filter specification
--- @param logname string|nil Optional log name
--- @param loglevel string|nil Optional log level
--- @return table WindowFilter instance
function WindowFilter.new(fn, logname, loglevel)
  local self = setmetatable({}, WindowFilter)

  -- Internal state
  self._filter = Filter.new()           -- Filter instance for rule matching
  self._subscriptions = Subscriptions.new()  -- Event subscriptions
  self._windows = {}                    -- {windowId -> {state table}}
  self._customFilter = nil              -- Custom filter function (if any)
  self._notifyfn = nil                  -- Notify callback for window list changes
  self._paused = false                  -- Paused state
  self._active = false                  -- Whether activated with Manager
  self._trackSpaces = false             -- Whether to track space changes
  self._sortOrder = nil                 -- Sort order for getWindows
  self._currentSpaceOnly = false        -- Only windows in current space
  self._allowedScreens = nil            -- Screen filter
  self._allowedRegions = nil            -- Region filter
  self._logname = logname               -- Log name
  self._loglevel = loglevel             -- Log level

  -- Parse constructor argument
  self:_parseConstructorArg(fn)

  return self
end

--- Parse the constructor argument and configure the filter.
--- @param fn nil|boolean|string|table|function
function WindowFilter:_parseConstructorArg(fn)
  if fn == nil then
    -- Default filter: allow all apps except ignoreAlways
    self._filter:setDefaultFilter(true)
  elseif fn == true then
    -- Allow all apps including ignored ones
    self._filter:setOverrideFilter(true)
  elseif fn == false then
    -- Reject all apps
    self._filter:setDefaultFilter(false)
  elseif type(fn) == 'string' then
    -- Single app name
    self._filter:setDefaultFilter(false)
    self._filter:setAppFilter(fn, true)
  elseif type(fn) == 'function' then
    -- Custom filter function
    self._customFilter = fn
  elseif type(fn) == 'table' then
    -- Could be app list or app rules
    if #fn > 0 then
      -- Array of app names
      self._filter:setDefaultFilter(false)
      for _, appName in ipairs(fn) do
        self._filter:setAppFilter(appName, true)
      end
    else
      -- Table of app rules
      for appName, rules in pairs(fn) do
        self._filter:setAppFilter(appName, rules)
      end
    end
  end
end

----------------------------------------------------------------------
-- Filter Configuration Methods (all return self for chaining)
----------------------------------------------------------------------

--- Set filter rules for a specific app.
--- @param appName string Application name
--- @param rules boolean|table Filter rules
--- @return table self
function WindowFilter:setAppFilter(appName, rules)
  self._filter:setAppFilter(appName, rules)
  self:_refreshAllWindows()
  return self
end

--- Set the default filter for apps without specific rules.
--- @param rules boolean|table Filter rules
--- @return table self
function WindowFilter:setDefaultFilter(rules)
  self._filter:setDefaultFilter(rules)
  self:_refreshAllWindows()
  return self
end

--- Set the override filter that applies to all windows.
--- @param rules boolean|table Filter rules
--- @return table self
function WindowFilter:setOverrideFilter(rules)
  self._filter:setOverrideFilter(rules)
  self:_refreshAllWindows()
  return self
end

--- Set filters from a table specification.
--- @param filters table Filter specification with optional sortOrder
--- @return table self
function WindowFilter:setFilters(filters)
  if not filters then return self end

  -- Handle sortOrder if present
  if filters.sortOrder then
    self._sortOrder = filters.sortOrder
  end

  -- Apply filters
  for appName, rules in pairs(filters) do
    if appName ~= 'sortOrder' then
      if appName == 'default' then
        self:setDefaultFilter(rules)
      elseif appName == 'override' then
        self:setOverrideFilter(rules)
      else
        self:setAppFilter(appName, rules)
      end
    end
  end

  return self
end

--- Get current filter configuration.
--- @return table Filter configuration
function WindowFilter:getFilters()
  return self._filter:getFilters()
end

--- Allow an app (shorthand for setAppFilter(app, true)).
--- @param appName string Application name
--- @return table self
function WindowFilter:allowApp(appName)
  return self:setAppFilter(appName, true)
end

--- Reject an app (shorthand for setAppFilter(app, false)).
--- @param appName string Application name
--- @return table self
function WindowFilter:rejectApp(appName)
  return self:setAppFilter(appName, false)
end

----------------------------------------------------------------------
-- Query Methods
----------------------------------------------------------------------

--- Check if an app is allowed by this filter.
--- @param appName string Application name
--- @return boolean
function WindowFilter:isAppAllowed(appName)
  -- Custom filter functions allow all apps (filtering at window level)
  if self._customFilter then
    return true
  end
  return self._filter:isAppAllowed(appName)
end

--- Check if a window is allowed by this filter.
--- @param hsWindow userdata hs.window object
--- @return boolean
function WindowFilter:isWindowAllowed(hsWindow)
  if not hsWindow then return false end

  -- Custom filter function bypasses Filter logic
  if self._customFilter then
    local ok, result = pcall(self._customFilter, hsWindow)
    return ok and result == true
  end

  -- Build WindowInfo and check against filter
  local windowInfo = WindowInfo.new(hsWindow)
  if not windowInfo.id then return false end

  local appInfo = nil
  local hsApp = safeCall(hsWindow.application, hsWindow)
  if hsApp then
    appInfo = AppInfo.new(hsApp)
  end

  local context = Manager.getInstance():getContext()
  return self._filter:matchWindow(windowInfo, appInfo, context)
end

----------------------------------------------------------------------
-- Configuration Methods
----------------------------------------------------------------------

--- Set the sort order for getWindows().
--- @param order string Sort order constant
--- @return table self
function WindowFilter:setSortOrder(order)
  self._sortOrder = order
  return self
end

-- Sorting comparators for getWindows
local sortingComparators = {
  focusedLast = function(a, b)
    return (a[STATE_TIME_FOCUSED] or 0) > (b[STATE_TIME_FOCUSED] or 0)
  end,
  focused = function(a, b)
    return (a[STATE_TIME_FOCUSED] or 0) < (b[STATE_TIME_FOCUSED] or 0)
  end,
  createdLast = function(a, b)
    return (a[STATE_TIME_CREATED] or 0) > (b[STATE_TIME_CREATED] or 0)
  end,
  created = function(a, b)
    return (a[STATE_TIME_CREATED] or 0) < (b[STATE_TIME_CREATED] or 0)
  end,
}

--- Get the currently allowed windows.
--- @param sortOrder string|nil Sort order (defaults to filter's sort order or focusedLast)
--- @return table List of hs.window objects
function WindowFilter:getWindows(sortOrder)
  -- One-shot activation: temporarily activate if not active
  local wasActive = self._active
  if not wasActive then
    Manager.getInstance():activate(self)
    self._active = true
  end

  -- Collect allowed windows with their state for sorting
  local windowsWithState = {}
  local manager = Manager.getInstance()
  local tracker = manager:getTracker()

  for windowId, state in pairs(self._windows) do
    if state[STATE_ALLOWED] then
      -- Get the hs.window object from tracker
      local hsWindow = nil
      if tracker then
        for _, appInfo in pairs(tracker.apps) do
          if appInfo.windows[windowId] then
            hsWindow = appInfo.windows[windowId]._window
            break
          end
        end
      end
      if hsWindow then
        windowsWithState[#windowsWithState + 1] = {
          window = hsWindow,
          state = state,
          [STATE_TIME_FOCUSED] = state[STATE_TIME_FOCUSED],
          [STATE_TIME_CREATED] = state[STATE_TIME_CREATED],
        }
      end
    end
  end

  -- Sort windows
  local order = sortOrder or self._sortOrder or 'focusedLast'
  local comparator = sortingComparators[order]
  if comparator then
    tsort(windowsWithState, comparator)
  end

  -- Extract just the hs.window objects
  local result = {}
  for i, entry in ipairs(windowsWithState) do
    result[i] = entry.window
  end

  -- Pause if wasn't active before (one-shot mode)
  if not wasActive then
    self:pause()
  end

  return result
end

--- Set whether to only include windows in current space.
--- @param current boolean
--- @return table self
function WindowFilter:setCurrentSpace(current)
  self._currentSpaceOnly = current
  if current then
    self._trackSpaces = true
    -- Update Manager registration if active
    if self._active then
      Manager.getInstance().spacesInstances[self] = true
    end
  end
  self:_refreshAllWindows()
  return self
end

--- Set allowed screens.
--- @param screens table|string Screen specification
--- @return table self
function WindowFilter:setScreens(screens)
  self._allowedScreens = screens
  self:_refreshAllWindows()
  return self
end

--- Set allowed regions.
--- @param regions table Region specification
--- @return table self
function WindowFilter:setRegions(regions)
  self._allowedRegions = regions
  self:_refreshAllWindows()
  return self
end

----------------------------------------------------------------------
-- Lifecycle Methods
----------------------------------------------------------------------

--- Pause the filter (stop receiving events).
--- @return table self
function WindowFilter:pause()
  self._paused = true
  return self
end

--- Resume the filter (start receiving events).
--- @return table self
function WindowFilter:resume()
  self._paused = false
  return self
end

--- Delete the filter (deactivate and clean up).
--- @return nil
function WindowFilter:delete()
  if self._active then
    Manager.getInstance():deactivate(self)
    self._active = false
  end
  self._subscriptions:removeAll()
  self._windows = {}
  return nil
end

--- Keep the filter active even without subscriptions.
--- @param keep boolean|nil Whether to keep active (default true)
--- @return table self
function WindowFilter:keepActive(keep)
  if keep == nil then keep = true end
  if keep and not self._active then
    Manager.getInstance():activate(self)
    self._active = true
  end
  return self
end

--- Create a copy of this filter.
--- @return table New WindowFilter with same configuration
function WindowFilter:copy()
  local new = WindowFilter.new()
  new._filter = self._filter:copy()
  new._customFilter = self._customFilter
  new._sortOrder = self._sortOrder
  new._currentSpaceOnly = self._currentSpaceOnly
  new._trackSpaces = self._trackSpaces
  new._allowedScreens = self._allowedScreens
  new._allowedRegions = self._allowedRegions
  return new
end

----------------------------------------------------------------------
-- Subscription Methods
----------------------------------------------------------------------

--- Subscribe to window events.
--- @param event string|table|function Event name(s) or callback
--- @param fn function|nil Callback function (if event is string/table)
--- @return table self
function WindowFilter:subscribe(event, fn)
  -- Handle different calling conventions
  if type(event) == 'function' then
    -- subscribe(fn) - subscribe to all events
    fn = event
    for eventName in pairs(windowfilter) do
      if type(windowfilter[eventName]) == 'number' then
        -- Skip non-event constants
      elseif type(eventName) == 'string' and eventName:match('^window') then
        self._subscriptions:add(eventName, fn)
      end
    end
  elseif type(event) == 'table' then
    -- subscribe({event = fn, ...})
    for eventName, callback in pairs(event) do
      self._subscriptions:add(eventName, callback)
    end
  else
    -- subscribe(event, fn)
    self._subscriptions:add(event, fn)
  end

  -- Activate with Manager if not already active
  if not self._active and self._subscriptions:hasAny() then
    Manager.getInstance():activate(self)
    self._active = true
  end

  return self
end

--- Unsubscribe from window events.
--- @param event string|table|function|nil Event name(s) or callback
--- @param fn function|nil Callback function (if event is string)
--- @return table self
function WindowFilter:unsubscribe(event, fn)
  if event == nil then
    -- unsubscribe() - remove all
    self._subscriptions:removeAll()
  elseif type(event) == 'function' then
    -- unsubscribe(fn) - remove this callback from all events
    self._subscriptions:removeAll(event)
  elseif type(event) == 'table' then
    -- unsubscribe({event, ...}) - remove all callbacks for these events
    for _, eventName in ipairs(event) do
      self._subscriptions:removeAll(eventName)
    end
  else
    -- unsubscribe(event, fn)
    if fn then
      self._subscriptions:remove(event, fn)
    else
      self._subscriptions:removeAll(event)
    end
  end

  return self
end

--- Unsubscribe all callbacks.
--- @return table self
function WindowFilter:unsubscribeAll()
  self._subscriptions:removeAll()
  return self
end

--- Set a callback to be notified when the window list changes.
--- @param fn function|nil Callback function (receives list of windows and event)
--- @param fnEmpty function|nil Optional callback for when filter has no windows
--- @param immediate boolean|nil If true, also call callback immediately
--- @return table self
function WindowFilter:notify(fn, fnEmpty, immediate)
  if fn ~= nil and type(fn) ~= 'function' then
    error('fn must be a function or nil', 2)
  end
  -- Handle optional fnEmpty and immediate arguments
  if fnEmpty and type(fnEmpty) ~= 'function' then
    fnEmpty = nil
    immediate = true
  end
  if fnEmpty ~= nil and type(fnEmpty) ~= 'function' then
    error('fnEmpty must be a function or nil', 2)
  end

  -- Store the notify function
  if fnEmpty then
    self._notifyfn = function(wins, event)
      if #wins > 0 then
        return fn(wins, event)
      else
        return fnEmpty()
      end
    end
  else
    self._notifyfn = fn
  end

  -- Activate or deactivate based on whether we have a notify function
  if fn then
    if not self._active then
      Manager.getInstance():activate(self)
      self._active = true
    end
  elseif not self._subscriptions:hasAny() then
    self:pause()
  end

  -- Call immediately if requested
  if fn and immediate then
    self._notifyfn(self:getWindows(), nil)
  end

  return self
end

----------------------------------------------------------------------
-- Event Handling (called by Manager)
----------------------------------------------------------------------

--- Handle an event from the Tracker via Manager.
--- @param eventType string Event type name
--- @param windowInfo table|nil WindowInfo object
--- @param appInfo table|nil AppInfo object
function WindowFilter:_handleTrackerEvent(eventType, windowInfo, appInfo)
  if self._paused then return end

  -- Handle app-level events
  if eventType == 'appActivated' or eventType == 'appDeactivated' or
     eventType == 'appHidden' or eventType == 'appUnhidden' then
    self:_handleAppEvent(eventType, appInfo)
    return
  end

  -- Handle space change
  if eventType == 'spaceChanged' then
    self:_handleSpaceChange()
    return
  end

  -- Window events require windowInfo
  if not windowInfo or not windowInfo.id then return end

  -- Get or create window state
  local windowId = windowInfo.id
  local oldState = self._windows[windowId]
  local newState = self:_computeWindowState(windowInfo, appInfo)
  local now = timer.secondsSinceEpoch()

  -- Handle window destruction
  if eventType == 'windowDestroyed' then
    if oldState and oldState[STATE_ALLOWED] then
      self:_emitEvent('windowDestroyed', windowInfo, appInfo)
      self:_emitStateChanges(oldState, {}, windowInfo, appInfo)
    end
    self._windows[windowId] = nil
    return
  end

  -- Track timestamps for sorting
  if oldState then
    -- Preserve existing timestamps
    newState[STATE_TIME_CREATED] = oldState[STATE_TIME_CREATED]
    newState[STATE_TIME_FOCUSED] = oldState[STATE_TIME_FOCUSED]
  end
  -- Set timeCreated if window first becomes allowed
  if newState[STATE_ALLOWED] and not newState[STATE_TIME_CREATED] then
    newState[STATE_TIME_CREATED] = now
  end
  -- Update timeFocused on focus events
  if eventType == 'windowFocused' and newState[STATE_ALLOWED] then
    newState[STATE_TIME_FOCUSED] = now
  end

  -- Store new state
  self._windows[windowId] = newState

  -- Emit the raw event if window is allowed
  if newState[STATE_ALLOWED] then
    self:_emitEvent(eventType, windowInfo, appInfo)
  end

  -- Emit state change events
  self:_emitStateChanges(oldState or {}, newState, windowInfo, appInfo)
end

--- Handle focus change event (called by Manager with extra context).
--- @param windowInfo table|nil WindowInfo for newly focused window
--- @param appInfo table|nil AppInfo for newly focused app
--- @param prevWindowInfo table|nil WindowInfo for previously focused window
function WindowFilter:_handleFocusChanged(windowInfo, appInfo, prevWindowInfo)
  if self._paused then return end

  -- Handle unfocus of previous window
  if prevWindowInfo and prevWindowInfo.id then
    local oldState = self._windows[prevWindowInfo.id]
    if oldState and oldState[STATE_ALLOWED] then
      oldState[STATE_FOCUSED] = false
      self:_emitEvent('windowUnfocused', prevWindowInfo, nil)
    end
  end

  -- Handle focus of new window
  if windowInfo and windowInfo.id then
    local newState = self._windows[windowInfo.id]
    if newState and newState[STATE_ALLOWED] then
      newState[STATE_FOCUSED] = true
      newState[STATE_TIME_FOCUSED] = timer.secondsSinceEpoch()
      self:_emitEvent('windowFocused', windowInfo, appInfo)
    end
  end
end

--- Compute the current state of a window.
--- @param windowInfo table WindowInfo object
--- @param appInfo table|nil AppInfo object
--- @return table State table
function WindowFilter:_computeWindowState(windowInfo, appInfo)
  local state = {}
  local context = Manager.getInstance():getContext()

  -- Check if window passes filter
  if self._customFilter then
    -- For custom filters, we need the actual window object
    -- windowInfo._window may be stale, so we check what we can
    state[STATE_ALLOWED] = true  -- Assume allowed, will be refined
  else
    state[STATE_ALLOWED] = self._filter:matchWindow(windowInfo, appInfo, context)
  end

  -- Check visibility (not hidden by app hide)
  state[STATE_VISIBLE] = not windowInfo.isHidden

  -- Check on screen (not minimized, has valid frame)
  state[STATE_ON_SCREEN] = not windowInfo.isMinimized and windowInfo.frame ~= nil

  -- Check current space (if tracking)
  if self._currentSpaceOnly then
    -- For now, assume in current space if visible
    -- Full implementation would check hs.spaces
    state[STATE_IN_SPACE] = state[STATE_VISIBLE]
  else
    state[STATE_IN_SPACE] = true
  end

  -- Check focused
  state[STATE_FOCUSED] = (context.focusedWindowId == windowInfo.id)

  return state
end

--- Emit state change events based on old vs new state.
--- @param oldState table Previous state
--- @param newState table New state
--- @param windowInfo table WindowInfo object
--- @param appInfo table|nil AppInfo object
function WindowFilter:_emitStateChanges(oldState, newState, windowInfo, appInfo)
  local wasAllowed = oldState[STATE_ALLOWED]
  local isAllowed = newState[STATE_ALLOWED]

  -- windowAllowed / windowRejected
  if isAllowed and not wasAllowed then
    self:_emitEvent('windowAllowed', windowInfo, appInfo)
  elseif not isAllowed and wasAllowed then
    self:_emitEvent('windowRejected', windowInfo, appInfo)
  end

  -- Only emit other state changes if window is/was allowed
  if not isAllowed and not wasAllowed then return end

  -- windowVisible / windowNotVisible
  local wasVisible = oldState[STATE_VISIBLE]
  local isVisible = newState[STATE_VISIBLE]
  if isAllowed and isVisible and not wasVisible then
    self:_emitEvent('windowVisible', windowInfo, appInfo)
  elseif wasAllowed and not isVisible and wasVisible then
    self:_emitEvent('windowNotVisible', windowInfo, appInfo)
  end

  -- windowOnScreen / windowNotOnScreen
  local wasOnScreen = oldState[STATE_ON_SCREEN]
  local isOnScreen = newState[STATE_ON_SCREEN]
  if isAllowed and isOnScreen and not wasOnScreen then
    self:_emitEvent('windowOnScreen', windowInfo, appInfo)
  elseif wasAllowed and not isOnScreen and wasOnScreen then
    self:_emitEvent('windowNotOnScreen', windowInfo, appInfo)
  end

  -- windowInCurrentSpace / windowNotInCurrentSpace
  local wasInSpace = oldState[STATE_IN_SPACE]
  local isInSpace = newState[STATE_IN_SPACE]
  if isAllowed and isInSpace and not wasInSpace then
    self:_emitEvent('windowInCurrentSpace', windowInfo, appInfo)
  elseif wasAllowed and not isInSpace and wasInSpace then
    self:_emitEvent('windowNotInCurrentSpace', windowInfo, appInfo)
  end

  -- windowMinimized / windowUnminimized (derived from onScreen)
  if isAllowed and not isOnScreen and wasOnScreen and not newState[STATE_VISIBLE] == oldState[STATE_VISIBLE] then
    -- State changed due to minimize, not visibility
    if windowInfo.isMinimized then
      self:_emitEvent('windowMinimized', windowInfo, appInfo)
    end
  elseif isAllowed and isOnScreen and not wasOnScreen then
    if not windowInfo.isMinimized and oldState[STATE_ON_SCREEN] == false then
      self:_emitEvent('windowUnminimized', windowInfo, appInfo)
    end
  end

  -- Call notify function if window list changed (allowed status changed)
  if self._notifyfn and (isAllowed ~= wasAllowed) then
    -- Get the event type that triggered this
    local eventType = isAllowed and 'windowAllowed' or 'windowRejected'
    self._notifyfn(self:getWindows(), eventType)
  end
end

--- Handle app-level events.
--- @param eventType string Event type
--- @param appInfo table AppInfo object
function WindowFilter:_handleAppEvent(eventType, appInfo)
  if not appInfo then return end

  -- Find windows belonging to this app and update their state
  for windowId, state in pairs(self._windows) do
    -- We'd need to check if window belongs to app
    -- For now, emit the app event if we have any allowed windows from this app
    if state[STATE_ALLOWED] then
      -- Emit hidden/shown events for windows
      if eventType == 'appHidden' then
        self:_emitEvent('windowHidden', {id = windowId}, appInfo)
      elseif eventType == 'appUnhidden' then
        self:_emitEvent('windowShown', {id = windowId}, appInfo)
      end
    end
  end
end

--- Handle space change.
function WindowFilter:_handleSpaceChange()
  -- Refresh all windows to update inCurrentSpace state
  self:_refreshAllWindows()
end

--- Refresh state for all tracked windows.
function WindowFilter:_refreshAllWindows()
  -- This will be called when filter configuration changes
  -- Re-evaluate all windows and emit appropriate events
  local manager = Manager.getInstance()
  if not manager:isRunning() then return end

  local tracker = manager:getTracker()
  if not tracker then return end

  local now = timer.secondsSinceEpoch()
  local context = manager:getContext()

  -- Re-process all tracked windows
  for _, appInfo in pairs(tracker.apps) do
    for _, windowInfo in pairs(appInfo.windows) do
      local oldState = self._windows[windowInfo.id] or {}
      local newState = self:_computeWindowState(windowInfo, appInfo)

      -- Preserve or set timestamps
      if oldState[STATE_TIME_CREATED] then
        newState[STATE_TIME_CREATED] = oldState[STATE_TIME_CREATED]
        newState[STATE_TIME_FOCUSED] = oldState[STATE_TIME_FOCUSED]
      elseif newState[STATE_ALLOWED] then
        newState[STATE_TIME_CREATED] = now
        -- Set timeFocused if this is the focused window
        if context.focusedWindowId == windowInfo.id then
          newState[STATE_TIME_FOCUSED] = now
        end
      end

      self._windows[windowInfo.id] = newState
      self:_emitStateChanges(oldState, newState, windowInfo, appInfo)
    end
  end
end

--- Emit an event to subscribers.
--- @param eventType string Event type
--- @param windowInfo table WindowInfo object
--- @param appInfo table|nil AppInfo object
function WindowFilter:_emitEvent(eventType, windowInfo, appInfo)
  -- Get the hs.window object if available
  local hsWindow = windowInfo._window
  local hsApp = appInfo and appInfo._app or nil
  local appName = appInfo and appInfo.name or nil

  self._subscriptions:emit(eventType, hsWindow, appName, eventType)
end

----------------------------------------------------------------------
-- String representation
----------------------------------------------------------------------

function WindowFilter:__tostring()
  local count = 0
  for _ in pairs(self._windows) do count = count + 1 end
  return sformat('WindowFilter: %d windows, active=%s, paused=%s',
    count, tostring(self._active), tostring(self._paused))
end

----------------------------------------------------------------------
-- Module-level new function
----------------------------------------------------------------------

--- Create a new WindowFilter.
--- @param fn nil|boolean|string|table|function Filter specification
--- @param logname string|nil Optional log name
--- @param loglevel string|nil Optional log level
--- @return table WindowFilter instance
function windowfilter.new(fn, logname, loglevel)
  return WindowFilter.new(fn, logname, loglevel)
end

-- Expose for testing
windowfilter._WindowFilter = WindowFilter

----------------------------------------------------------------------
-- SECTION 12: MODULE VARIABLES AND SINGLETONS
----------------------------------------------------------------------

--- hs.window.filter.allowedWindowRoles
--- Variable
--- A table of window roles allowed by default.
--- Set roles as keys: `{AXStandardWindow=true, AXDialog=true}`
windowfilter.allowedWindowRoles = {
  AXStandardWindow = true,
  AXDialog = true,
  AXSystemDialog = true,
}

--- hs.window.filter.ignoreInDefaultFilter
--- Variable
--- Apps to reject in the default filter (but not in new(true)).
--- These are apps with transient windows unlikely to be useful.
windowfilter.ignoreInDefaultFilter = {}
do
  local SKIP_APPS_TRANSIENT_WINDOWS = {
    'Spotlight', 'Notification Center', 'loginwindow', 'ScreenSaverEngine',
    'PressAndHold', 'PopClip', 'Pastebot', 'Fantastical', 'Keychain Access',
    'SecurityAgent', 'Reeder', 'ScreenFloat - Screenshot Tools', 'Dropzone',
    'Alfred', 'Alfred 2', 'Alfred 3', 'Alfred Preferences', 'Keka',
    'Pastebot', 'Bartender', 'Bartender 2', 'Bartender 3',
    'Focus', 'Timing', 'Timing 2', 'Flux', 'Flycut',
  }
  for _, appname in ipairs(SKIP_APPS_TRANSIENT_WINDOWS) do
    windowfilter.ignoreInDefaultFilter[appname] = true
  end
end

-- Singletons for default and defaultCurrentSpace
local defaultwf = nil
local defaultCurrentSpacewf = nil

-- Create the default windowfilter singleton
local function makeDefault()
  if not defaultwf then
    defaultwf = windowfilter.new(true, 'wf-default')
    -- Reject apps in ignoreInDefaultFilter
    for appname in pairs(windowfilter.ignoreInDefaultFilter) do
      defaultwf:rejectApp(appname)
    end
    -- Special handling for Hammerspoon
    defaultwf:setAppFilter('Hammerspoon', {
      allowTitles = {'Preferences', 'Console'},
      allowRoles = 'AXStandardWindow'
    })
    -- Default to visible windows only
    defaultwf:setDefaultFilter({visible = true})
  end
  return defaultwf
end

-- Create the defaultCurrentSpace windowfilter singleton
local function makeDefaultCurrentSpace()
  if not defaultCurrentSpacewf then
    defaultCurrentSpacewf = makeDefault():copy()
    defaultCurrentSpacewf:setCurrentSpace(true)
  end
  return defaultCurrentSpacewf
end

----------------------------------------------------------------------
-- SECTION 13: MODULE FUNCTIONS
----------------------------------------------------------------------

--- hs.window.filter.copy(wf) -> hs.window.filter object
--- Function
--- Creates a copy of a windowfilter.
--- @param wf table WindowFilter to copy
--- @param logname string|nil Optional log name
--- @param loglevel string|nil Optional log level
--- @return table New WindowFilter copy
function windowfilter.copy(wf, logname, loglevel)
  if not wf or not wf.copy then
    error('wf must be a windowfilter object', 2)
  end
  local new = wf:copy()
  if logname then new._logname = logname end
  if loglevel then new._loglevel = loglevel end
  return new
end

--- hs.window.filter.iswf(t) -> boolean
--- Function
--- Checks if a value is a windowfilter object.
--- @param t any Value to check
--- @return boolean true if t is a windowfilter
function windowfilter.iswf(t)
  return type(t) == 'table' and t._filter ~= nil and t._subscriptions ~= nil
end

--- hs.window.filter.setLogLevel(lvl)
--- Function
--- Sets the log level for the window filter module.
--- @param lvl string|number Log level
function windowfilter.setLogLevel(lvl)
  -- Store for future use when proper logging is added
  windowfilter._logLevel = lvl
end

--- hs.window.filter.switchedToSpace(space)
--- Function
--- Manually notify the module of a space change.
--- Use this when the system doesn't detect space changes automatically.
--- @param space number Space number (currently unused)
function windowfilter.switchedToSpace(space)
  local manager = Manager.getInstance()
  if manager:isRunning() then
    manager:_handleSpaceChange()
  end
end

-- Batch operations for ensuring tracker runs during multiple operations
local batches = {}

--- hs.window.filter.startBatchOperation() -> string
--- Function
--- Start a batch operation (keeps tracker running).
--- @return string Batch ID to pass to stopBatchOperation
function windowfilter.startBatchOperation()
  local id = tostring(timer.secondsSinceEpoch()) .. tostring(math.random(100000))
  batches[id] = true
  -- Ensure manager is running
  local manager = Manager.getInstance()
  if not manager:isRunning() then
    manager:_start()
  end
  return id
end

--- hs.window.filter.stopBatchOperation(id)
--- Function
--- Stop a batch operation.
--- @param id string Batch ID from startBatchOperation
function windowfilter.stopBatchOperation(id)
  batches[id] = nil
  -- If no more batches and no active instances, stop
  if not next(batches) then
    local manager = Manager.getInstance()
    if manager.instanceCount == 0 then
      manager:_stop()
    end
  end
end

----------------------------------------------------------------------
-- SECTION 14: DIRECTION AND FOCUS METHODS
----------------------------------------------------------------------

-- Add direction methods to WindowFilter using loop to avoid repetition
local window = hs.window
for _, dir in ipairs{'East', 'North', 'West', 'South'} do
  -- windowsToEast/North/West/South
  WindowFilter['windowsTo' .. dir] = function(self, win, ...)
    return window['windowsTo' .. dir](win, self:getWindows(), ...)
  end
  -- focusWindowEast/North/West/South
  WindowFilter['focusWindow' .. dir] = function(self, win, ...)
    return window['focusWindow' .. dir](win, self:getWindows(), ...)
  end
  -- Module-level focusEast/North/West/South
  windowfilter['focus' .. dir] = function()
    local wf = makeDefaultCurrentSpace()
    wf:keepActive()
    wf['focusWindow' .. dir](wf, nil, nil, true)
  end
end

----------------------------------------------------------------------
-- RETURN MODULE WITH METATABLE
----------------------------------------------------------------------

local rawget = rawget
return setmetatable(windowfilter, {
  -- Lazy singletons via __index
  __index = function(t, k)
    if k == 'default' then
      return makeDefault()
    elseif k == 'defaultCurrentSpace' then
      return makeDefaultCurrentSpace()
    else
      return rawget(t, k)
    end
  end,
  -- Module callable: windowfilter(...) -> windowfilter.new(...):getWindows()
  __call = function(_, ...)
    return windowfilter.new(...):getWindows()
  end,
})
