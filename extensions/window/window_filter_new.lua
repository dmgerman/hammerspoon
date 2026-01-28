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
-- SECTION 5: PLACEHOLDER FOR FUTURE COMPONENTS
----------------------------------------------------------------------
-- Components will be added in subsequent steps:
-- Step 2: WindowInfo, AppInfo
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
