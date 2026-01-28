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
-- SECTION 6: PLACEHOLDER FOR FUTURE COMPONENTS
----------------------------------------------------------------------
-- Components will be added in subsequent steps:
-- Step 3: FilterRules, Filter
-- Step 4: PreFilter
-- Step 5: Events, Subscriptions
-- Step 6: Tracker
-- Step 7: Manager
-- Step 8: WindowFilter class (public API)
-- Step 9: Default filters, module functions

----------------------------------------------------------------------
-- RETURN MODULE
----------------------------------------------------------------------

return windowfilter
