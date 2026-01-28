# hs.window.filter Rewrite Plan

**Date**: 2025-01-28
**Status**: Planning
**Target**: Full API-compatible replacement for upstream `hs.window.filter`
**Estimated Size**: ~1200-1500 lines (vs current ~2400)

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Core Design Principles](#3-core-design-principles)
4. [Module Structure](#4-module-structure)
5. [Data Structures](#5-data-structures)
6. [Component Specifications](#6-component-specifications)
7. [API Compatibility Matrix](#7-api-compatibility-matrix)
8. [Performance Targets](#8-performance-targets)
9. [Test Specifications](#9-test-specifications)
10. [Implementation Phases](#10-implementation-phases)
11. [Future Deprecation Candidates](#11-future-deprecation-candidates)
12. [Deferred Features](#12-deferred-features)
13. [Implementation Guidance for Claude](#13-implementation-guidance-for-claude)

---

## 1. Goals and Non-Goals

### Goals

1. **Full API compatibility** with current `hs.window.filter`
2. **Production-grade quality** - no crashes, graceful degradation
3. **Cleaner architecture** - separation of concerns, minimal global state
4. **Better performance** - early filtering, reduced watcher count
5. **Maintainable code** - consistent style, comprehensive documentation
6. **Testable design** - pure functions where possible, injectable dependencies

### Non-Goals

1. New features beyond current API
2. Breaking changes to public API
3. Support for undocumented internal behaviors
4. Micro-optimizations at cost of readability

---

## 2. Architecture Overview

### Current Architecture (Problems)

```
┌─────────────────────────────────────────────────────────────┐
│                    window_filter.lua                         │
│  ┌─────────────────────────────────────────────────────────┐│
│  │  Global State (10+ mutable tables)                      ││
│  │  - apps, global, activeInstances, spacesInstances...   ││
│  └─────────────────────────────────────────────────────────┘│
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌────────────────┐ │
│  │ App      │ │ Window   │ │ WF Class │ │ Event Handlers │ │
│  │ Class    │ │ Class    │ │          │ │                │ │
│  └──────────┘ └──────────┘ └──────────┘ └────────────────┘ │
│  Mixed responsibilities, tight coupling, late filtering     │
└─────────────────────────────────────────────────────────────┘
```

### New Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    window_filter.lua                         │
│                    (Public API Layer)                        │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────────────────────────────────────────────────┐│
│  │              WindowFilterManager (Singleton)             ││
│  │  - Owns global state                                     ││
│  │  - Manages tracker lifecycle                             ││
│  │  - Coordinates filter instances                          ││
│  └─────────────────────────────────────────────────────────┘│
│         │                    │                    │          │
│         ▼                    ▼                    ▼          │
│  ┌────────────┐      ┌─────────────┐      ┌─────────────┐   │
│  │  Tracker   │      │   Filter    │      │   Events    │   │
│  │            │      │   (Pure)    │      │             │   │
│  │ - Watchers │      │ - Rules     │      │ - Emit      │   │
│  │ - Apps     │      │ - Match     │      │ - Subscribe │   │
│  │ - Windows  │      │ - No state  │      │ - Dispatch  │   │
│  └────────────┘      └─────────────┘      └─────────────┘   │
│         │                                                    │
│         ▼                                                    │
│  ┌─────────────────────────────────────────────────────────┐│
│  │                    PreFilter                             ││
│  │  - Bundle ID blacklist                                   ││
│  │  - Role/title requirements                               ││
│  │  - Applied BEFORE watcher creation                       ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
```

### Key Architectural Changes

| Aspect         | Current                   | New                         |
|----------------|---------------------------|-----------------------------|
| Global state   | 10+ loose tables          | Single Manager object       |
| Filtering      | At query time             | At watcher creation + query |
| Event flow     | Complex "inserted" chains | Simple emit/subscribe       |
| Spaces         | Eager full refresh        | Lazy on-demand query        |
| Error handling | Inconsistent              | pcall everywhere            |
| Dependencies   | Implicit globals          | Explicit injection          |

---

## 3. Core Design Principles

### 3.1 Fail Gracefully

Every accessibility API call must be protected:

```lua
-- WRONG
local title = win:title()

-- RIGHT
local ok, title = pcall(win.title, win)
title = ok and title or ''
```

### 3.2 Filter Early

Don't create watchers for windows that will never be allowed:

```lua
-- Pseudocode
function onWindowDetected(win, app)
    if not preFilter:shouldTrack(win, app) then
        return  -- No watcher created
    end
    createWatcher(win)
end
```

### 3.3 Minimize State

Prefer computed properties over cached state:

```lua
-- WRONG: Cached state that can become stale
window.isInCurrentSpace = true  -- Updated on space change

-- RIGHT: Computed on demand
function Window:isInCurrentSpace()
    return self:computeSpaceStatus()
end
```

### 3.4 Pure Filter Logic

Filter matching should be a pure function with no side effects:

```lua
-- Filter.matches(rules, windowInfo) -> boolean
-- No globals, no state mutation, easily testable
```

### 3.5 Consistent Style

Follow `window.lua` conventions:
- Local caching at top: `local pairs, ipairs, type = pairs, ipairs, type`
- Consistent spacing
- Line length ~100 chars max
- LuaDoc for all public APIs

---

## 4. Module Structure

Single file, organized into clear sections:

```lua
-- hs.window.filter
-- Line counts are estimates

----------------------------------------------------------------------
-- SECTION 1: IMPORTS AND CONSTANTS (~50 lines)
----------------------------------------------------------------------
local pairs, ipairs, type = pairs, ipairs, type
-- ... other imports

local Config = {
    RETRY_DELAY = 0.2,
    MAX_RETRIES = 5,
    -- ...
}

----------------------------------------------------------------------
-- SECTION 2: PREFILTER (~80 lines)
----------------------------------------------------------------------
-- Bundle ID blacklist, role requirements, early filtering

----------------------------------------------------------------------
-- SECTION 3: FILTER RULES (~150 lines)
----------------------------------------------------------------------
-- Pure functions for matching windows against rules

----------------------------------------------------------------------
-- SECTION 4: WINDOW INFO (~100 lines)
----------------------------------------------------------------------
-- Window data structure, safe property access

----------------------------------------------------------------------
-- SECTION 5: APP INFO (~80 lines)
----------------------------------------------------------------------
-- App data structure, window collection

----------------------------------------------------------------------
-- SECTION 6: TRACKER (~250 lines)
----------------------------------------------------------------------
-- Watcher management, app/window lifecycle

----------------------------------------------------------------------
-- SECTION 7: EVENTS (~150 lines)
----------------------------------------------------------------------
-- Event definitions, subscription, emission

----------------------------------------------------------------------
-- SECTION 8: MANAGER (~100 lines)
----------------------------------------------------------------------
-- Singleton coordinator, global state owner

----------------------------------------------------------------------
-- SECTION 9: WINDOWFILTER CLASS (~300 lines)
----------------------------------------------------------------------
-- Public API implementation

----------------------------------------------------------------------
-- SECTION 10: UTILITIES (~100 lines)
----------------------------------------------------------------------
-- Direction methods, convenience functions

----------------------------------------------------------------------
-- SECTION 11: DEFAULT FILTERS (~80 lines)
----------------------------------------------------------------------
-- Default windowfilter, ignoreAlways, etc.

-- Total: ~1440 lines
```

---

## 5. Data Structures

### 5.1 Configuration

```lua
local Config = {
    -- Timing
    RETRY_DELAY = 0.2,           -- Seconds between registration retries
    MAX_RETRIES = 5,             -- Max attempts to register window
    MOVED_DEBOUNCE = 0.5,        -- Debounce for move events
    TITLE_DEBOUNCE = 0.5,        -- Debounce for title changes
    SPACE_CHANGE_DELAY = 0.5,    -- Delay after space switch
    ZOMBIE_CLEANUP_INTERVAL = 300, -- Seconds between zombie checks

    -- Performance
    ACCESSIBILITY_TIMEOUT = 0.5, -- Max wait for AX response
    SKIP_SLOW_APPS = false,      -- Skip apps exceeding timeout

    -- Filtering
    ALLOWED_ROLES = {
        AXStandardWindow = true,
        AXDialog = true,
        AXSystemDialog = true,
    },
}
```

### 5.2 PreFilter Configuration

```lua
-- User-configurable pre-filter
windowfilter.preFilter = {
    -- Bundle IDs to never track
    ignoreBundleIDs = {
        ['com.apple.WebKit.WebContent'] = true,
        ['com.google.Chrome.helper'] = true,
    },

    -- App names to never track (existing ignoreAlways)
    ignoreAppNames = { ... },

    -- Requirements for creating watchers
    requireTitle = false,        -- Skip windows with empty title
    requireRole = false,         -- Skip windows with empty role
    minTitleLength = 0,          -- Minimum title length
    allowedRoles = nil,          -- If set, only these roles tracked
}
```

### 5.3 WindowInfo

Immutable snapshot of window state:

```lua
-- Created by Tracker, passed to Filter
local WindowInfo = {}
WindowInfo.__index = WindowInfo

function WindowInfo.new(hsWindow)
    local self = setmetatable({}, WindowInfo)

    -- All properties fetched once, with pcall protection
    self.id = safeCall(hsWindow.id, hsWindow) or 0
    self.title = safeCall(hsWindow.title, hsWindow) or ''
    self.role = safeCall(hsWindow.subrole, hsWindow) or ''
    self.frame = safeCall(hsWindow.frame, hsWindow) or Geometry.rect(0,0,0,0)
    self.screenId = safeGetScreenId(hsWindow)
    self.isMinimized = safeCall(hsWindow.isMinimized, hsWindow) or false
    self.isVisible = safeCall(hsWindow.isVisible, hsWindow) or false
    self.isFullscreen = safeCall(hsWindow.isFullScreen, hsWindow) or false
    self.hasTitlebar = safeCall(hsWindow.zoomButtonRect, hsWindow) ~= nil

    -- Computed
    self.isHidden = not self.isVisible and not self.isMinimized

    -- References
    self._window = hsWindow

    return self
end

function WindowInfo:refresh()
    -- Update mutable properties (frame, title, visibility, etc.)
    -- Called after move/title change events
end
```

### 5.4 AppInfo

```lua
local AppInfo = {}
AppInfo.__index = AppInfo

function AppInfo.new(hsApp, pid)
    local self = setmetatable({}, AppInfo)

    self.pid = pid
    self.name = safeCall(hsApp.name, hsApp) or ''
    self.bundleID = safeCall(hsApp.bundleID, hsApp) or ''
    self.isHidden = safeCall(hsApp.isHidden, hsApp) or false
    self.isFrontmost = safeCall(hsApp.isFrontmost, hsApp) or false

    self.windows = {}  -- id -> WindowInfo
    self.watcher = nil
    self._app = hsApp

    return self
end
```

### 5.5 Filter Rules

```lua
-- Internal representation of filter rules
local FilterRules = {}
FilterRules.__index = FilterRules

function FilterRules.new()
    return setmetatable({
        override = nil,      -- Applied first, can reject all
        appRules = {},       -- appname -> rule or false
        default = nil,       -- Fallback rule
    }, FilterRules)
end

-- Single rule structure:
-- {
--     visible = true/false/nil,
--     currentSpace = true/false/nil,
--     fullscreen = true/false/nil,
--     focused = true/false/nil,
--     activeApplication = true/false/nil,
--     hasTitlebar = true/false/nil,
--     allowTitles = number/string/{strings}/nil,
--     rejectTitles = string/{strings}/nil,
--     allowRoles = string/{strings}/'*'/nil,
--     allowScreens = {screen hints}/nil,
--     rejectScreens = {screen hints}/nil,
--     allowRegions = {rects}/nil,        -- Deferred
--     rejectRegions = {rects}/nil,       -- Deferred
-- }
```

### 5.6 Event Subscriptions

```lua
-- Per-instance subscription storage
local Subscriptions = {}
Subscriptions.__index = Subscriptions

function Subscriptions.new()
    return setmetatable({
        -- event -> { fn -> true }
        callbacks = {},
    }, Subscriptions)
end

function Subscriptions:add(event, fn)
    if not self.callbacks[event] then
        self.callbacks[event] = {}
    end
    self.callbacks[event][fn] = true
end

function Subscriptions:remove(event, fn)
    if self.callbacks[event] then
        self.callbacks[event][fn] = nil
        if not next(self.callbacks[event]) then
            self.callbacks[event] = nil
        end
    end
end

function Subscriptions:emit(event, window, appName)
    local fns = self.callbacks[event]
    if fns then
        for fn in pairs(fns) do
            fn(window, appName, event)
        end
    end
end
```

---

## 6. Component Specifications

### 6.1 PreFilter

**Purpose**: Decide whether to create a watcher for a window.

```lua
local PreFilter = {}

function PreFilter.shouldTrack(hsWindow, hsApp, config)
    -- Returns: boolean, string (reason if false)

    local bundleID = safeCall(hsApp.bundleID, hsApp)
    local appName = safeCall(hsApp.name, hsApp)

    -- Check bundle ID blacklist
    if bundleID and config.ignoreBundleIDs[bundleID] then
        return false, 'bundleID blacklisted'
    end

    -- Check app name blacklist
    if appName and config.ignoreAppNames[appName] then
        return false, 'appName blacklisted'
    end

    -- Check app name pattern
    if config.ignoreAppPattern and appName then
        if appName:match(config.ignoreAppPattern) then
            return false, 'appName matches ignore pattern'
        end
    end

    -- Get window properties
    local title = safeCall(hsWindow.title, hsWindow) or ''
    local role = safeCall(hsWindow.subrole, hsWindow) or ''

    -- Check title requirements
    if config.requireTitle and #title == 0 then
        return false, 'empty title'
    end

    if config.minTitleLength and #title < config.minTitleLength then
        return false, 'title too short'
    end

    -- Check role requirements
    if config.requireRole and #role == 0 then
        return false, 'empty role'
    end

    if config.allowedRoles and not config.allowedRoles[role] then
        return false, 'role not allowed'
    end

    return true, nil
end
```

### 6.2 Filter (Pure Functions)

**Purpose**: Match windows against filter rules.

```lua
local Filter = {}

-- Main entry point
function Filter.matches(rules, windowInfo, context)
    -- rules: FilterRules object
    -- windowInfo: WindowInfo object
    -- context: { focusedWindowId, activeAppPid, currentScreens }
    -- Returns: boolean, string (reason if false)

    -- Check override filter (applied to all)
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
    local appRule = rules.appRules[windowInfo.appName]
    if appRule == false then
        return false, 'app rejected'
    end
    if appRule then
        return Filter.matchesRule(appRule, windowInfo, context)
    end

    -- Check default filter
    if rules.default == false then
        return false, 'default rejects all'
    end
    if rules.default then
        return Filter.matchesRule(rules.default, windowInfo, context)
    end

    -- No filter = allow
    return true, nil
end

-- Match single rule
function Filter.matchesRule(rule, windowInfo, context)
    -- Visibility
    if rule.visible ~= nil then
        if rule.visible ~= windowInfo.isVisible then
            return false, 'visible mismatch'
        end
    end

    -- Current space
    if rule.currentSpace ~= nil then
        if rule.currentSpace ~= windowInfo.isInCurrentSpace then
            return false, 'currentSpace mismatch'
        end
    end

    -- Fullscreen
    if rule.fullscreen ~= nil then
        if rule.fullscreen ~= windowInfo.isFullscreen then
            return false, 'fullscreen mismatch'
        end
    end

    -- Focused
    if rule.focused ~= nil then
        local isFocused = (windowInfo.id == context.focusedWindowId)
        if rule.focused ~= isFocused then
            return false, 'focused mismatch'
        end
    end

    -- Active application
    if rule.activeApplication ~= nil then
        local isActive = (windowInfo.appPid == context.activeAppPid)
        if rule.activeApplication ~= isActive then
            return false, 'activeApplication mismatch'
        end
    end

    -- Titlebar
    if rule.hasTitlebar ~= nil then
        if rule.hasTitlebar ~= windowInfo.hasTitlebar then
            return false, 'hasTitlebar mismatch'
        end
    end

    -- Allow titles
    if rule.allowTitles then
        if not Filter.matchesTitleRule(rule.allowTitles, windowInfo.title) then
            return false, 'allowTitles mismatch'
        end
    end

    -- Reject titles
    if rule.rejectTitles then
        if Filter.matchesTitlePattern(rule.rejectTitles, windowInfo.title) then
            return false, 'rejectTitles matched'
        end
    end

    -- Roles
    local allowedRoles = rule.allowRoles or Config.ALLOWED_ROLES
    if allowedRoles ~= '*' then
        if not allowedRoles[windowInfo.role] then
            return false, 'role not allowed'
        end
    end

    -- Screens (only for visible windows)
    if windowInfo.isVisible then
        if rule.allowScreens then
            if not Filter.matchesScreens(rule._allowedScreenIds, windowInfo.screenId) then
                return false, 'screen not allowed'
            end
        end
        if rule.rejectScreens then
            if Filter.matchesScreens(rule._rejectedScreenIds, windowInfo.screenId) then
                return false, 'screen rejected'
            end
        end
    end

    return true, nil
end

-- Helper: Match title against rule
function Filter.matchesTitleRule(rule, title)
    if type(rule) == 'number' then
        return #title >= rule
    end
    return Filter.matchesTitlePattern(rule, title)
end

-- Helper: Match title against pattern(s)
function Filter.matchesTitlePattern(patterns, title)
    if type(patterns) == 'string' then
        patterns = {patterns}
    end
    for _, pattern in ipairs(patterns) do
        if title:match(pattern) then
            return true
        end
    end
    return false
end

-- Helper: Match screen
function Filter.matchesScreens(screenIds, windowScreenId)
    return screenIds and screenIds[windowScreenId]
end
```

### 6.3 Tracker

**Purpose**: Manage watchers, track apps and windows.

```lua
local Tracker = {}
Tracker.__index = Tracker

function Tracker.new(manager)
    local self = setmetatable({}, Tracker)

    self.manager = manager
    self.apps = {}              -- pid -> AppInfo
    self.appWatcher = nil       -- hs.application.watcher
    self.pendingApps = {}       -- pid -> retry timer
    self.windowRetries = {}     -- window -> retry timer

    return self
end

function Tracker:start()
    if self.appWatcher then return end

    -- Create app watcher
    self.appWatcher = application.watcher.new(function(name, event, app)
        self:onAppEvent(name, event, app)
    end)

    -- Register existing apps
    for _, app in ipairs(application.runningApplications()) do
        self:registerApp(app)
    end

    self.appWatcher:start()
end

function Tracker:stop()
    if not self.appWatcher then return end

    -- Stop all watchers
    for pid, appInfo in pairs(self.apps) do
        self:unregisterApp(pid)
    end

    -- Stop pending timers
    for pid, timer in pairs(self.pendingApps) do
        timer:stop()
    end
    self.pendingApps = {}

    for win, timer in pairs(self.windowRetries) do
        timer:stop()
    end
    self.windowRetries = {}

    self.appWatcher:stop()
    self.appWatcher = nil
end

function Tracker:registerApp(hsApp, retry)
    local pid = hsApp:pid()
    if self.apps[pid] then return end

    -- Pre-filter: skip non-GUI apps
    if hsApp:kind() < 0 then return end

    local appName = hsApp:name()
    local bundleID = hsApp:bundleID()

    -- Pre-filter: check blacklists
    if not PreFilter.shouldTrackApp(hsApp, self.manager.preFilter) then
        return
    end

    retry = (retry or 0) + 1

    -- Check if app is ready (has focusedWindow)
    local fw = safeCall(hsApp.focusedWindow, hsApp)

    if fw or retry > Config.MAX_RETRIES then
        -- Register the app
        local appInfo = AppInfo.new(hsApp, pid)
        self.apps[pid] = appInfo

        -- Create watcher for this app
        appInfo.watcher = hsApp:newWatcher(function(element, event)
            self:onWindowEvent(element, event, pid)
        end, pid)
        appInfo.watcher:start({
            uiwatcher.windowCreated,
            uiwatcher.focusedWindowChanged,
        })

        -- Register existing windows
        self:registerAppWindows(appInfo)

        self.manager:onAppRegistered(appInfo)
    else
        -- Retry later
        self.pendingApps[pid] = timer.doAfter(
            retry * Config.RETRY_DELAY,
            function()
                self.pendingApps[pid] = nil
                self:registerApp(hsApp, retry)
            end
        )
    end
end

function Tracker:registerAppWindows(appInfo)
    local windows = safeCall(appInfo._app.allWindows, appInfo._app) or {}

    for _, hsWindow in ipairs(windows) do
        self:registerWindow(hsWindow, appInfo)
    end
end

function Tracker:registerWindow(hsWindow, appInfo, retry)
    local id = safeCall(hsWindow.id, hsWindow)

    if not id then
        -- Retry if no ID yet
        retry = (retry or 0) + 1
        if retry <= Config.MAX_RETRIES then
            self.windowRetries[hsWindow] = timer.doAfter(
                retry * Config.RETRY_DELAY,
                function()
                    self.windowRetries[hsWindow] = nil
                    self:registerWindow(hsWindow, appInfo, retry)
                end
            )
        end
        return
    end

    if appInfo.windows[id] then return end

    -- Pre-filter check
    if not PreFilter.shouldTrack(hsWindow, appInfo._app, self.manager.preFilter) then
        return
    end

    -- Create window info
    local windowInfo = WindowInfo.new(hsWindow)
    windowInfo.appName = appInfo.name
    windowInfo.appPid = appInfo.pid

    -- Create window watcher
    windowInfo.watcher = hsWindow:newWatcher(function(element, event)
        self:onWindowElementEvent(event, appInfo.pid, id)
    end)
    windowInfo.watcher:start({
        uiwatcher.elementDestroyed,
        uiwatcher.windowMoved,
        uiwatcher.windowResized,
        uiwatcher.windowMinimized,
        uiwatcher.windowUnminimized,
        uiwatcher.titleChanged,
    })

    appInfo.windows[id] = windowInfo
    self.manager:onWindowCreated(windowInfo, appInfo)
end

function Tracker:unregisterWindow(windowInfo, appInfo)
    if windowInfo.watcher then
        windowInfo.watcher:stop()
    end
    appInfo.windows[windowInfo.id] = nil
    self.manager:onWindowDestroyed(windowInfo, appInfo)
end

function Tracker:unregisterApp(pid)
    local appInfo = self.apps[pid]
    if not appInfo then return end

    -- Unregister all windows
    for id, windowInfo in pairs(appInfo.windows) do
        self:unregisterWindow(windowInfo, appInfo)
    end

    -- Stop app watcher
    if appInfo.watcher then
        appInfo.watcher:stop()
    end

    self.apps[pid] = nil
    self.manager:onAppUnregistered(appInfo)
end

-- Event handlers (pseudocode)
function Tracker:onAppEvent(name, event, app)
    -- Handle launched, terminated, activated, deactivated, hidden, unhidden
end

function Tracker:onWindowEvent(element, event, pid)
    -- Handle windowCreated, focusedWindowChanged
end

function Tracker:onWindowElementEvent(event, pid, windowId)
    -- Handle elementDestroyed, windowMoved, etc.
end

-- Zombie cleanup
function Tracker:cleanupZombies()
    for pid, appInfo in pairs(self.apps) do
        if not application.applicationForPID(pid) then
            self:unregisterApp(pid)
        end
    end
end
```

### 6.4 Events

**Purpose**: Define events and coordinate emission.

```lua
local Events = {}

-- Event constants
Events.windowCreated = 'windowCreated'
Events.windowDestroyed = 'windowDestroyed'
Events.windowMoved = 'windowMoved'
Events.windowMinimized = 'windowMinimized'
Events.windowUnminimized = 'windowUnminimized'
Events.windowHidden = 'windowHidden'
Events.windowUnhidden = 'windowUnhidden'
Events.windowVisible = 'windowVisible'
Events.windowNotVisible = 'windowNotVisible'
Events.windowInCurrentSpace = 'windowInCurrentSpace'
Events.windowNotInCurrentSpace = 'windowNotInCurrentSpace'
Events.windowOnScreen = 'windowOnScreen'
Events.windowNotOnScreen = 'windowNotOnScreen'
Events.windowFullscreened = 'windowFullscreened'
Events.windowUnfullscreened = 'windowUnfullscreened'
Events.windowFocused = 'windowFocused'
Events.windowUnfocused = 'windowUnfocused'
Events.windowTitleChanged = 'windowTitleChanged'

-- Pseudo-events
Events.windowAllowed = 'windowAllowed'
Events.windowRejected = 'windowRejected'
Events.hasWindow = 'hasWindow'
Events.hasNoWindows = 'hasNoWindows'
Events.windowsChanged = 'windowsChanged'

-- All events set
Events.all = {}
for k, v in pairs(Events) do
    if type(v) == 'string' then
        Events.all[v] = true
    end
end

function Events.isValid(event)
    return Events.all[event] == true
end
```

### 6.5 Manager (Singleton)

**Purpose**: Coordinate tracker, maintain global context.

```lua
local Manager = {}
Manager.__index = Manager

local instance = nil

function Manager.getInstance()
    if not instance then
        instance = Manager.new()
    end
    return instance
end

function Manager.new()
    local self = setmetatable({}, Manager)

    self.tracker = nil
    self.instances = {}          -- wf -> true (active instances)
    self.spacesInstances = {}    -- wf -> true (spaces-aware)
    self.screensInstances = {}   -- wf -> true (screens-aware)

    self.focusedWindowId = nil
    self.activeAppPid = nil
    self.preFilter = windowfilter.preFilter or {}

    self.screenWatcher = nil
    self.spacesWatcher = nil
    self.cleanupTimer = nil

    return self
end

function Manager:activate(wf)
    if self.instances[wf] then return end

    self.instances[wf] = true

    -- Start tracker if first instance
    if not self.tracker then
        self.tracker = Tracker.new(self)
        self.tracker:start()
        self:startCleanupTimer()
    end

    -- Refresh windows for this instance
    self:refreshInstance(wf)
end

function Manager:deactivate(wf)
    self.instances[wf] = nil
    self.spacesInstances[wf] = nil
    self.screensInstances[wf] = nil

    -- Stop tracker if no instances
    if not next(self.instances) and not next(self.spacesInstances) then
        if self.tracker then
            self.tracker:stop()
            self.tracker = nil
        end
        self:stopCleanupTimer()
    end
end

function Manager:getContext()
    return {
        focusedWindowId = self.focusedWindowId,
        activeAppPid = self.activeAppPid,
        -- currentScreens computed on demand
    }
end

function Manager:refreshInstance(wf)
    wf.windows = {}
    if not self.tracker then return end

    local context = self:getContext()

    for pid, appInfo in pairs(self.tracker.apps) do
        for id, windowInfo in pairs(appInfo.windows) do
            if Filter.matches(wf.rules, windowInfo, context) then
                wf.windows[windowInfo] = true
            end
        end
    end
end

-- Callbacks from Tracker
function Manager:onWindowCreated(windowInfo, appInfo)
    local context = self:getContext()

    for wf in pairs(self.instances) do
        if Filter.matches(wf.rules, windowInfo, context) then
            wf.windows[windowInfo] = true
            wf.subscriptions:emit(Events.windowCreated, windowInfo._window, appInfo.name)
            wf.subscriptions:emit(Events.windowAllowed, windowInfo._window, appInfo.name)
        end
    end
end

function Manager:onWindowDestroyed(windowInfo, appInfo)
    for wf in pairs(self.instances) do
        if wf.windows[windowInfo] then
            wf.subscriptions:emit(Events.windowDestroyed, windowInfo._window, appInfo.name)
            wf.subscriptions:emit(Events.windowRejected, windowInfo._window, appInfo.name)
            wf.windows[windowInfo] = nil
        end
    end
end

-- ... similar handlers for other events
```

### 6.6 WindowFilter Class (Public API)

```lua
local WF = {}
WF.__index = WF

function WF.new(fn, logname, loglevel)
    local self = setmetatable({}, WF)

    self.rules = FilterRules.new()
    self.subscriptions = Subscriptions.new()
    self.windows = {}
    self.sortOrder = 'focusedLast'
    self.log = logname and logger.new(logname, loglevel) or log

    -- Handle constructor arguments
    if fn == nil then
        -- Copy default
        return windowfilter.copy(windowfilter.default, logname, loglevel)
    elseif fn == true then
        -- Empty filter (allow all)
        return self
    elseif fn == false then
        -- Reject all
        self.rules.default = false
        return self
    elseif type(fn) == 'function' then
        -- Custom function
        self.customFilter = fn
        return self
    elseif type(fn) == 'string' then
        -- Single app
        self.rules.default = false
        self.rules.appRules[fn] = { visible = true }
        return self
    elseif type(fn) == 'table' then
        -- Multiple apps or filter config
        self.rules.default = false
        self:setFilters(fn)
        return self
    end

    error('invalid argument to windowfilter.new()', 2)
end

-- API Methods

function WF:setAppFilter(appname, filter)
    -- Validate and set filter for app
    -- Returns self for chaining
end

function WF:setDefaultFilter(filter)
    return self:setAppFilter('default', filter)
end

function WF:setOverrideFilter(filter)
    return self:setAppFilter('override', filter)
end

function WF:setFilters(filters)
    for k, v in pairs(filters) do
        if k == 'sortOrder' then
            self:setSortOrder(v)
        elseif type(k) == 'string' then
            self:setAppFilter(k, v)
        elseif type(k) == 'number' and type(v) == 'string' then
            self:setAppFilter(v, true)
        end
    end
    return self
end

function WF:getFilters()
    -- Return copy of current filters
end

function WF:allowApp(appname)
    return self:setAppFilter(appname, true)
end

function WF:rejectApp(appname)
    return self:setAppFilter(appname, false)
end

function WF:isAppAllowed(appname)
    return self.rules.appRules[appname] ~= false
end

function WF:isWindowAllowed(hsWindow)
    -- Check if window matches current rules
end

function WF:getWindows(sortOrder)
    local manager = Manager.getInstance()
    local wasActive = manager.instances[self]

    if not wasActive then
        manager:activate(self)
    end

    local result = {}
    for windowInfo in pairs(self.windows) do
        table.insert(result, windowInfo)
    end

    -- Sort
    local comparator = SortComparators[sortOrder or self.sortOrder]
    table.sort(result, comparator)

    -- Extract hs.window objects
    local windows = {}
    for i, info in ipairs(result) do
        windows[i] = info._window
    end

    if not wasActive then
        manager:deactivate(self)
    end

    return windows
end

function WF:subscribe(event, fn, immediate)
    -- Validate and add subscription
    -- Activate if needed
    Manager.getInstance():activate(self)
    return self
end

function WF:unsubscribe(event, fn)
    -- Remove subscription
    return self
end

function WF:unsubscribeAll()
    self.subscriptions = Subscriptions.new()
    return self:pause()
end

function WF:pause()
    Manager.getInstance():deactivate(self)
    return self
end

function WF:resume()
    Manager.getInstance():activate(self)
    return self
end

function WF:delete()
    self:unsubscribeAll()
    self.rules = nil
    self.windows = nil
    setmetatable(self, nil)
end

function WF:setSortOrder(order)
    self.sortOrder = order
    return self
end

function WF:setCurrentSpace(val)
    local override = self.rules.override or {}
    override.currentSpace = val
    return self:setOverrideFilter(override)
end

function WF:setScreens(screens)
    local override = self.rules.override or {}
    override.allowScreens = screens
    return self:setOverrideFilter(override)
end

function WF:setRegions(regions)
    local override = self.rules.override or {}
    override.allowRegions = regions
    return self:setOverrideFilter(override)
end

-- Keep active (for modules using getWindows without subscribing)
function WF:keepActive()
    self._keepActive = true
    Manager.getInstance():activate(self)
    return self
end
```

---

## 7. API Compatibility Matrix

| API                                                          | Status       | Notes                 |
|--------------------------------------------------------------|--------------|-----------------------|
| `windowfilter.new(nil/true/false/string/table/fn)`           | Full         | All constructor forms |
| `windowfilter.copy(wf)`                                      | Full         |                       |
| `windowfilter.default`                                       | Full         | Lazy singleton        |
| `windowfilter.defaultCurrentSpace`                           | Full         | Lazy singleton        |
| `:setAppFilter(name, filter)`                                | Full         |                       |
| `:setDefaultFilter(filter)`                                  | Full         |                       |
| `:setOverrideFilter(filter)`                                 | Full         |                       |
| `:setFilters(table)`                                         | Full         |                       |
| `:getFilters()`                                              | Full         |                       |
| `:allowApp(name)`                                            | Full         |                       |
| `:rejectApp(name)`                                           | Full         |                       |
| `:isAppAllowed(name)`                                        | Full         |                       |
| `:isWindowAllowed(window)`                                   | Full         |                       |
| `:getWindows(sortOrder)`                                     | Full         |                       |
| `:subscribe(event, fn, immediate)`                           | Full         |                       |
| `:unsubscribe(event, fn)`                                    | Full         |                       |
| `:unsubscribeAll()`                                          | Full         |                       |
| `:pause()`                                                   | Full         |                       |
| `:resume()`                                                  | Full         |                       |
| `:delete()`                                                  | Full         |                       |
| `:setSortOrder(order)`                                       | Full         |                       |
| `:setCurrentSpace(val)`                                      | Full         |                       |
| `:setScreens(screens)`                                       | Full         |                       |
| `:setRegions(regions)`                                       | **Deferred** | See Section 12        |
| `:windowsToEast/West/North/South`                            | Full         |                       |
| `:focusWindowEast/West/North/South`                          | Full         |                       |
| `windowfilter.focusEast/West/North/South()`                  | Full         |                       |
| `windowfilter.switchedToSpace(n)`                            | Full         |                       |
| `windowfilter.forceRefreshOnSpaceChange`                     | Full         |                       |
| `windowfilter.ignoreAlways`                                  | Full         |                       |
| `windowfilter.ignoreInDefaultFilter`                         | Full         |                       |
| `windowfilter.allowedWindowRoles`                            | Full         |                       |
| `windowfilter.isGuiApp(name)`                                | Full         |                       |
| `windowfilter.sortByFocused/FocusedLast/Created/CreatedLast` | Full         |                       |
| All event constants                                          | Full         |                       |

---

## 8. Performance Targets

| Metric                 | Target         | Measurement Method             |
|------------------------|----------------|--------------------------------|
| `getWindows()` cold    | < 200ms        | First call after start         |
| `getWindows()` warm    | < 50ms         | Subsequent calls               |
| Startup time           | < 500ms        | Time to register all apps      |
| Event callback latency | < 10ms         | Time from OS event to callback |
| Memory per window      | < 2KB          | Lua table overhead             |
| Watcher count          | ~50% reduction | Vs current (due to pre-filter) |

### Benchmarking Code

```lua
-- benchmark.lua
local function benchmark(name, fn, iterations)
    iterations = iterations or 100
    collectgarbage('collect')

    local start = hs.timer.absoluteTime()
    for i = 1, iterations do
        fn()
    end
    local elapsed = (hs.timer.absoluteTime() - start) / 1e9

    print(string.format('%s: %.3fms avg (%.3fms total, %d iterations)',
        name, elapsed / iterations * 1000, elapsed * 1000, iterations))
end

-- Usage
local wf = hs.window.filter.new():keepActive()
benchmark('getWindows', function() wf:getWindows() end)
```

---

## 9. Test Specifications

### 9.1 Test Framework

Uses Hammerspoon's built-in test framework (same format as `test_window.lua`):

**Test file location:** `~/git.forks/hammerspoon/extensions/window/test_window_filter.lua`

**Format:**
- Global `testXxx()` functions (CamelCase after "test")
- Built-in assertions: `assertIsEqual()`, `assertTrue()`, `assertFalse()`, `assertIsTable()`, `assertIsNotNil()`, `assertGreaterThan()`, `assertIsBoolean()`, `assertIsString()`, `assertIsNumber()`
- Each test returns `success()`

**Running tests:**
```bash
# Full test suite (CI)
cd ~/git.forks/hammerspoon
./scripts/build.sh test -e -d -s Release

# Manual testing during development (in Hammerspoon console)
dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua')
```

### 9.2 Internal Component Tests

For testing internal components (Filter, PreFilter) during development, add test functions to `test_window_filter.lua`. These test the internal pure functions before they're wired into the full module.

```lua
-- Internal Filter tests (added to test_window_filter.lua during Step 3)

function testFilterMatchesVisibleTrue()
  -- Test internal Filter.matchesRule function
  local Filter = _G._windowFilterInternals.Filter  -- Exposed for testing
  local rule = { visible = true }
  local windowInfo = { isVisible = true }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertTrue(ok)
  return success()
end

function testFilterRejectsInvisible()
  local Filter = _G._windowFilterInternals.Filter
  local rule = { visible = true }
  local windowInfo = { isVisible = false }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertFalse(ok)
  return success()
end

function testFilterAllowTitlesNumber()
  local Filter = _G._windowFilterInternals.Filter
  local rule = { allowTitles = 1 }
  local windowInfo = { title = 'Hello', role = 'AXStandardWindow' }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertTrue(ok)
  return success()
end

function testFilterRejectsEmptyTitle()
  local Filter = _G._windowFilterInternals.Filter
  local rule = { allowTitles = 1 }
  local windowInfo = { title = '', role = 'AXStandardWindow' }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertFalse(ok)
  return success()
end

function testFilterAllowTitlesPattern()
  local Filter = _G._windowFilterInternals.Filter
  local rule = { allowTitles = 'Console' }
  local windowInfo = { title = 'Hammerspoon Console', role = 'AXStandardWindow' }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertTrue(ok)
  return success()
end

function testFilterRejectsUnknownRole()
  local Filter = _G._windowFilterInternals.Filter
  local rule = {}  -- Default role filtering
  local windowInfo = { title = 'Test', role = 'AXUnknown' }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertFalse(ok)
  return success()
end

function testFilterAllowsAllRolesWithStar()
  local Filter = _G._windowFilterInternals.Filter
  local rule = { allowRoles = '*' }
  local windowInfo = { title = 'Test', role = 'AXUnknown' }
  local ok = Filter.matchesRule(rule, windowInfo, {})
  assertTrue(ok)
  return success()
end

function testFilterOverrideFalseRejectsAll()
  local Filter = _G._windowFilterInternals.Filter
  local rules = { override = false, default = {} }
  local windowInfo = { isVisible = true, role = 'AXStandardWindow' }
  local ok = Filter.matches(rules, windowInfo, {})
  assertFalse(ok)
  return success()
end
```

**Note:** During development, expose internal components via `_G._windowFilterInternals` for testing. Remove this exposure before final release, or gate it behind a debug flag.

### 9.3 PreFilter Tests

```lua
-- PreFilter tests (added to test_window_filter.lua during Step 4)

function testPreFilterRejectsBundleIDBlacklist()
  local PreFilter = _G._windowFilterInternals.PreFilter
  local config = {
    ignoreBundleIDs = { ['com.apple.WebKit.WebContent'] = true }
  }
  -- Mock objects
  local win = { title = function() return 'Test' end, subrole = function() return 'AXStandardWindow' end }
  local app = { bundleID = function() return 'com.apple.WebKit.WebContent' end, name = function() return 'Safari Web Content' end }

  local ok = PreFilter.shouldTrack(win, app, config)
  assertFalse(ok)
  return success()
end

function testPreFilterAllowsNonBlacklistedBundleID()
  local PreFilter = _G._windowFilterInternals.PreFilter
  local config = {
    ignoreBundleIDs = { ['com.apple.WebKit.WebContent'] = true }
  }
  local win = { title = function() return 'Test' end, subrole = function() return 'AXStandardWindow' end }
  local app = { bundleID = function() return 'com.apple.Safari' end, name = function() return 'Safari' end }

  local ok = PreFilter.shouldTrack(win, app, config)
  assertTrue(ok)
  return success()
end

function testPreFilterRejectsEmptyTitleWhenRequired()
  local PreFilter = _G._windowFilterInternals.PreFilter
  local config = { requireTitle = true }
  local win = { title = function() return '' end, subrole = function() return 'AXStandardWindow' end }
  local app = { bundleID = function() return 'com.test' end, name = function() return 'Test' end }

  local ok = PreFilter.shouldTrack(win, app, config)
  assertFalse(ok)
  return success()
end
```

### 9.4 API Compatibility Tests

**Note:** The comprehensive API compatibility tests are defined in Step 0's contract tests (Section 13.3). Those tests serve as the definitive behavioral contract. The tests in `test_window_filter.lua` include all constructor, chaining, filter, subscription, and module-level API tests.

### 9.5 Performance Tests

```lua
-- Performance tests (added to test_window_filter.lua during Step 10)

function testGetWindowsPerformance()
  local wf = hs.window.filter
  local f = wf.new():keepActive()

  -- Warm up
  for i = 1, 5 do f:getWindows() end

  -- Measure
  local iterations = 50
  local start = hs.timer.absoluteTime()
  for i = 1, iterations do
    f:getWindows()
  end
  local elapsed = (hs.timer.absoluteTime() - start) / 1e9
  local avgMs = elapsed / iterations * 1000

  print(string.format('    getWindows avg: %.2fms (target: <50ms)', avgMs))
  -- Target: < 50ms warm
  assertTrue(avgMs < 100)  -- Use 100ms as CI-safe threshold

  f:delete()
  return success()
end

function testWatcherCountReduction()
  -- Helper to count watchers
  local function countWatchers()
    local count = 0
    for k, v in pairs(debug.getregistry()) do
      if type(v) == 'userdata' and tostring(v):match('uielement%.watcher') then
        count = count + 1
      end
    end
    return count
  end

  -- This test documents watcher count for comparison
  local count = countWatchers()
  print(string.format('    Current watcher count: %d', count))

  -- Target: New implementation should have ~50% fewer watchers
  -- This is validated manually by comparing old vs new
  assertGreaterThan(0, count)
  return success()
end
```

---

## 10. Implementation Phases

### Phase 0: Contract Tests (Week 1)

1. Create `test_window_filter.lua` in `~/git.forks/hammerspoon/extensions/window/`
2. Write comprehensive contract tests against current `hs.window.filter`
3. Verify all tests pass against current implementation
4. These tests define the behavioral contract for the rewrite

**Deliverable**: Contract test suite (~40 tests) that passes against current implementation

### Phase 1: Core Infrastructure (Week 1)

1. Implement safeCall utility
2. Implement WindowInfo
3. Implement AppInfo
4. Implement FilterRules
5. Write internal component tests

**Deliverable**: Core data structures with tests

### Phase 2: Filter Logic (Week 1-2)

1. Implement Filter.matchesRule
2. Implement Filter.matches
3. Implement all filter criteria
4. Write comprehensive filter tests

**Deliverable**: Pure filter logic with 100% test coverage

### Phase 3: PreFilter (Week 2)

1. Implement PreFilter.shouldTrack
2. Add configuration options
3. Write tests

**Deliverable**: PreFilter with tests

### Phase 4: Tracker (Week 2-3)

1. Implement Tracker class
2. App registration/unregistration
3. Window registration/unregistration
4. Event handling
5. Zombie cleanup
6. Write tests

**Deliverable**: Tracker with tests

### Phase 5: Manager (Week 3)

1. Implement Manager singleton
2. Instance coordination
3. Context management
4. Event routing
5. Write tests

**Deliverable**: Manager with tests

### Phase 6: Public API (Week 3-4)

1. Implement WF class
2. All public methods
3. Default windowfilter
4. Compatibility verification
5. Write API tests

**Deliverable**: Full API implementation with tests

### Phase 7: Integration & Polish (Week 4)

1. Integration tests
2. Performance benchmarking
3. Memory testing
4. Documentation
5. Edge case handling

**Deliverable**: Production-ready module

---

## 11. Future Deprecation Candidates

These API elements could be improved in a future breaking version:

### 11.1 `setAppFilter` Overloading

**Current**: `setAppFilter(name, filter)` where filter can be `false`, `true`, `nil`, or a table.

**Better**: Separate methods
```lua
:rejectApp(name)           -- Clear intent
:allowApp(name)            -- Clear intent
:setAppRules(name, rules)  -- For complex rules
```

**Migration**: Keep current API, add new methods, deprecate in v2.

### 11.2 Constructor Overloading

**Current**: `new(nil|true|false|string|table|function)`

**Better**: Named constructors
```lua
windowfilter.empty()           -- Allow all
windowfilter.rejectAll()       -- Reject all
windowfilter.forApps({...})    -- Specific apps
windowfilter.withRules({...})  -- Full config
windowfilter.custom(fn)        -- Custom function
```

**Migration**: Keep `new()`, add named constructors.

### 11.3 Pseudo-events as Separate Subscriptions

**Current**: Pseudo-events (`hasWindow`, `windowsChanged`) mixed with real events.

**Better**: Separate subscription types
```lua
:subscribe(event, fn)          -- Real events only
:onWindowsChanged(fn)          -- Aggregate changes
:onFirstWindow(fn)             -- Has window
:onNoWindows(fn)               -- Lost all windows
```

### 11.4 `forceRefreshOnSpaceChange` Global

**Current**: Module-level variable affecting all instances.

**Better**: Per-instance configuration
```lua
:setSpaceRefreshPolicy('eager'|'lazy'|'manual')
```

---

## 12. Deferred Features

### 12.1 `allowRegions` / `rejectRegions`

**Reason**: Rarely used, adds complexity.

**Implementation cost**: ~50 lines

**Plan**: Implement in v1.1 after core is stable.

**Temporary behavior**: Accept the parameters, log warning, ignore them.

```lua
if rule.allowRegions then
    log.w('allowRegions not yet implemented, ignoring')
end
```

---

## 13. Implementation Guidance for Claude

This section provides explicit guidance for Claude (the AI assistant) on how to implement this rewrite. The implementation should be **incremental and test-driven**, not a single monolithic step.

### 13.1 Core Principles

1. **Never write a component without tests first** - Write the test, see it fail, implement the component, see it pass
2. **Small, verifiable steps** - Each step should be completable and testable in a single session
3. **API compatibility verification at each step** - Don't proceed if existing API behavior breaks
4. **Commit after each working milestone** - User can request commits at stable points

### 13.2 Recommended Implementation Order

The implementation should follow this dependency order, where each step builds on the previous:

```
Step 0: Test Framework + Tests for CURRENT implementation (the contract)
        ↓
Step 1: Utilities + Core data structures
        ↓
Step 2: WindowInfo + AppInfo
        ↓
Step 3: FilterRules + Filter (pure functions)
        ↓
Step 4: PreFilter
        ↓
Step 5: Events + Subscriptions
        ↓
Step 6: Tracker
        ↓
Step 7: Manager
        ↓
Step 8: WindowFilter Class (public API)
        ↓
Step 9: Default filters + module-level functions
        ↓
Step 10: Run Step 0 tests against new implementation + performance validation
```

### 13.3 Step-by-Step Implementation Details

#### Step 0: Contract Tests (~300 lines)

**Purpose**: Establish the behavioral contract by testing the CURRENT `hs.window.filter` implementation. These tests define what "API compatible" means. The new implementation must pass all these tests.

**File to create:**
- `~/git.forks/hammerspoon/extensions/window/test_window_filter.lua`

**Uses Hammerspoon's built-in test framework** (same as `test_window.lua`):
- Global `testXxx()` functions
- Built-in assertions: `assertIsEqual()`, `assertTrue()`, `assertFalse()`, `assertIsTable()`, `assertIsNotNil()`, `assertGreaterThan()`
- Each test returns `success()`

**Contract tests (using Hammerspoon test format):**

```lua
-- test_window_filter.lua
-- Contract tests for hs.window.filter
-- These tests define the behavioral contract that any implementation must satisfy.

local wf = hs.window.filter

-- ============================================================================
-- CONSTRUCTOR TESTS
-- ============================================================================

function testNewDefault()
  -- new() returns copy of default filter
  local f = wf.new()
  assertIsNotNil(f)
  -- Should reject apps in ignoreAlways
  assertFalse(f:isAppAllowed('Spotlight'))
  assertFalse(f:isAppAllowed('Notification Center'))
  -- Should allow normal apps
  assertTrue(f:isAppAllowed('Safari'))
  assertTrue(f:isAppAllowed('Finder'))
  f:delete()
  return success()
end

function testNewTrue()
  -- new(true) allows all apps including ignored
  local f = wf.new(true)
  assertTrue(f:isAppAllowed('Spotlight'))
  assertTrue(f:isAppAllowed('Safari'))
  f:delete()
  return success()
end

function testNewFalse()
  -- new(false) rejects all apps
  local f = wf.new(false)
  local wins = f:getWindows()
  assertIsEqual(0, #wins)
  f:delete()
  return success()
end

function testNewSingleApp()
  -- new("AppName") allows only that app
  local f = wf.new('Finder')
  assertTrue(f:isAppAllowed('Finder'))
  assertFalse(f:isAppAllowed('Safari'))
  assertFalse(f:isAppAllowed('Spotlight'))
  f:delete()
  return success()
end

function testNewAppList()
  -- new({"App1", "App2"}) allows listed apps only
  local f = wf.new({'Finder', 'Safari'})
  assertTrue(f:isAppAllowed('Finder'))
  assertTrue(f:isAppAllowed('Safari'))
  assertFalse(f:isAppAllowed('TextEdit'))
  f:delete()
  return success()
end

function testNewAppRules()
  -- new({App1=rule, App2=rule}) applies rules
  local f = wf.new({Finder = {visible = true}, Safari = false})
  assertTrue(f:isAppAllowed('Finder'))
  assertFalse(f:isAppAllowed('Safari'))
  f:delete()
  return success()
end

function testNewFunction()
  -- new(function) uses custom filter
  local f = wf.new(function(win)
    return win:title():match('Console')
  end)
  assertIsNotNil(f)
  assertIsEqual('function', type(f.isWindowAllowed))
  f:delete()
  return success()
end

-- ============================================================================
-- METHOD CHAINING TESTS
-- ============================================================================

function testSetAppFilterReturnsself()
  local f = wf.new(true)
  local result = f:setAppFilter('Test', false)
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testSetDefaultFilterReturnsSelf()
  local f = wf.new(true)
  local result = f:setDefaultFilter({visible = true})
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testAllowAppReturnsSelf()
  local f = wf.new(false)
  local result = f:allowApp('Test')
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testRejectAppReturnsSelf()
  local f = wf.new(true)
  local result = f:rejectApp('Test')
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testMethodChaining()
  local f = wf.new(true)
    :rejectApp('App1')
    :rejectApp('App2')
    :setDefaultFilter({visible = true})
  assertFalse(f:isAppAllowed('App1'))
  assertFalse(f:isAppAllowed('App2'))
  f:delete()
  return success()
end

-- ============================================================================
-- FILTER RULES TESTS
-- ============================================================================

function testVisibleFilter()
  hs.openConsole()  -- Ensure at least one visible window
  local f = wf.new(true):setDefaultFilter({visible = true})
  local wins = f:getWindows()
  for _, win in ipairs(wins) do
    assertTrue(win:isVisible())
  end
  f:delete()
  return success()
end

function testAllowTitlesNumber()
  hs.openConsole()
  local f = wf.new(true):setDefaultFilter({allowTitles = 1})
  local wins = f:getWindows()
  for _, win in ipairs(wins) do
    assertGreaterThan(0, #win:title())
  end
  f:delete()
  return success()
end

function testRejectAppExcludes()
  local f = wf.new():rejectApp('Finder')
  local wins = f:getWindows()
  for _, win in ipairs(wins) do
    local appName = win:application():name()
    assertTrue(appName ~= 'Finder')
  end
  f:delete()
  return success()
end

-- ============================================================================
-- getWindows TESTS
-- ============================================================================

function testGetWindowsReturnsTable()
  local f = wf.new()
  local wins = f:getWindows()
  assertIsTable(wins)
  f:delete()
  return success()
end

function testGetWindowsReturnsWindowObjects()
  hs.openConsole()
  local f = wf.new()
  local wins = f:getWindows()
  if #wins > 0 then
    local win = wins[1]
    assertIsEqual('function', type(win.id))
    assertIsEqual('function', type(win.title))
    assertIsEqual('function', type(win.application))
  end
  f:delete()
  return success()
end

function testGetWindowsSortOrder()
  local f = wf.new()
  local wins1 = f:getWindows('focusedLast')
  local wins2 = f:getWindows('createdLast')
  assertIsTable(wins1)
  assertIsTable(wins2)
  f:delete()
  return success()
end

-- ============================================================================
-- SUBSCRIPTION TESTS
-- ============================================================================

function testSubscribeReturnsSelf()
  local f = wf.new()
  local result = f:subscribe(wf.windowFocused, function() end)
  assertIsEqual(f, result)
  f:unsubscribeAll()
  f:delete()
  return success()
end

function testUnsubscribeReturnsSelf()
  local f = wf.new()
  local fn = function() end
  f:subscribe(wf.windowFocused, fn)
  local result = f:unsubscribe(wf.windowFocused, fn)
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testUnsubscribeAllReturnsSelf()
  local f = wf.new()
  f:subscribe(wf.windowFocused, function() end)
  local result = f:unsubscribeAll()
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testPauseReturnsSelf()
  local f = wf.new()
  local result = f:pause()
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testResumeReturnsSelf()
  local f = wf.new()
  f:pause()
  local result = f:resume()
  assertIsEqual(f, result)
  f:delete()
  return success()
end

-- ============================================================================
-- MODULE-LEVEL API TESTS
-- ============================================================================

function testDefaultExists()
  assertIsNotNil(wf.default)
  local wins = wf.default:getWindows()
  assertIsTable(wins)
  return success()
end

function testDefaultCurrentSpaceExists()
  assertIsNotNil(wf.defaultCurrentSpace)
  return success()
end

function testIgnoreAlwaysIsTable()
  assertIsTable(wf.ignoreAlways)
  return success()
end

function testEventConstantsExist()
  assertIsNotNil(wf.windowCreated)
  assertIsNotNil(wf.windowDestroyed)
  assertIsNotNil(wf.windowFocused)
  assertIsNotNil(wf.windowUnfocused)
  assertIsNotNil(wf.windowMoved)
  assertIsNotNil(wf.windowMinimized)
  assertIsNotNil(wf.windowUnminimized)
  return success()
end

function testSortOrderConstantsExist()
  assertIsNotNil(wf.sortByFocused)
  assertIsNotNil(wf.sortByFocusedLast)
  assertIsNotNil(wf.sortByCreated)
  assertIsNotNil(wf.sortByCreatedLast)
  return success()
end

-- ============================================================================
-- COPY TESTS
-- ============================================================================

function testCopyCreatesIndependentCopy()
  local f1 = wf.new(true)
  local f2 = wf.copy(f1)
  f1:rejectApp('TestApp')
  -- f2 should not be affected
  assertTrue(f2:isAppAllowed('TestApp'))
  f1:delete()
  f2:delete()
  return success()
end

-- ============================================================================
-- ADDITIONAL EDGE CASE TESTS
-- ============================================================================

function testSetFiltersWithSortOrder()
  local f = wf.new(true)
  f:setFilters({sortOrder = 'focusedLast'})
  assertIsNotNil(f)
  f:delete()
  return success()
end

function testGetFilters()
  local f = wf.new(true):setDefaultFilter({visible = true})
  local filters = f:getFilters()
  assertIsTable(filters)
  f:delete()
  return success()
end

function testIsWindowAllowed()
  hs.openConsole()
  local f = wf.new()
  local win = hs.window.focusedWindow()
  if win then
    local allowed = f:isWindowAllowed(win)
    assertIsBoolean(allowed)
  end
  f:delete()
  return success()
end

function testKeepActive()
  local f = wf.new()
  local result = f:keepActive()
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testSetCurrentSpace()
  local f = wf.new()
  local result = f:setCurrentSpace(true)
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testSetScreens()
  local f = wf.new()
  local result = f:setScreens(hs.screen.mainScreen())
  assertIsEqual(f, result)
  f:delete()
  return success()
end
```

**How to run:**

```bash
# From ~/git.forks/hammerspoon/
./scripts/build.sh test -e -d -s Release

# Or run manually in Hammerspoon console during development:
# (after adding test_window_filter.lua to the extensions/window/ directory)
dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua')
```

**Why this matters:**

1. Tests capture *actual* behavior, not documented behavior
2. If a test fails against the current implementation, we discover undocumented edge cases
3. The new implementation has a clear target: pass all these tests
4. Prevents "it works differently but I think it's better" mistakes
5. Tests integrate with Hammerspoon's existing CI infrastructure

**Exit criteria:**
- All contract tests pass against current `hs.window.filter`
- Tests run successfully via `./scripts/build.sh test`
- Any test failures are investigated and either fixed (test bug) or documented (actual behavior differs from expectation)

---

#### Step 1: Utilities + Core Constants (~100 lines)

**Files to create:**
- `window_filter_new.lua` - Start the new module with just utilities

**What to implement:**
```lua
-- Utilities only
local function safeCall(fn, obj, ...) ... end
local function safeGetScreenId(hsWindow) ... end
local Config = { ... }
```

**Verification:**
- Run test framework manually in Hammerspoon console
- Verify safeCall handles nil, errors, and valid results

**Exit criteria:** Test framework runs, utilities work in isolation

---

#### Step 2: WindowInfo + AppInfo (~150 lines)

**What to implement:**
- `WindowInfo.new(hsWindow)` - Safe property extraction
- `WindowInfo:refresh()` - Update mutable properties
- `AppInfo.new(hsApp, pid)` - Safe property extraction

**Tests to write first:**
```lua
Test.describe('WindowInfo', function()
    Test.it('extracts title safely', ...)
    Test.it('handles nil window gracefully', ...)
    Test.it('refresh updates frame', ...)
end)
```

**Verification:**
- Create WindowInfo from real window in console
- Verify all properties accessible without error

**Exit criteria:** Data structures work with real Hammerspoon objects

---

#### Step 3: FilterRules + Filter (~200 lines)

**What to implement:**
- `FilterRules.new()` - Rule container
- `Filter.matchesRule(rule, windowInfo, context)` - Single rule matching
- `Filter.matches(rules, windowInfo, context)` - Full filter chain
- All filter criteria from Section 6.2

**Tests to write first:**
- All tests from Section 9.2 (test_filter.lua)
- Additional edge cases for each filter criterion

**Verification:**
- Create mock windowInfo objects
- Verify each filter criterion works in isolation
- Verify filter chain (override → app → default) works correctly

**Exit criteria:** 100% of filter tests pass, no side effects

---

#### Step 4: PreFilter (~80 lines)

**What to implement:**
- `PreFilter.shouldTrackApp(hsApp, config)` - App-level pre-filtering
- `PreFilter.shouldTrack(hsWindow, hsApp, config)` - Window-level pre-filtering
- Configuration structure from Section 5.2

**Tests to write first:**
- All tests from Section 9.3 (test_prefilter.lua)
- Tests for bundle ID blacklist, app name blacklist, title/role requirements

**Verification:**
- Test with real apps (Safari, Chrome, Keyboard Maestro)
- Verify phantom windows would be filtered

**Exit criteria:** PreFilter correctly identifies windows to skip

---

#### Step 5: Events + Subscriptions (~100 lines)

**What to implement:**
- `Events` constant table from Section 6.4
- `Subscriptions.new()`, `:add()`, `:remove()`, `:emit()`

**Tests to write first:**
```lua
Test.describe('Subscriptions', function()
    Test.it('emits to registered callback', ...)
    Test.it('does not emit after unsubscribe', ...)
    Test.it('handles multiple callbacks', ...)
end)
```

**Verification:**
- Subscribe, emit, verify callback called
- Unsubscribe, emit, verify callback NOT called

**Exit criteria:** Event system works in isolation

---

#### Step 6: Tracker (~300 lines)

**What to implement:**
- `Tracker.new(manager)`, `:start()`, `:stop()`
- App registration with PreFilter check
- Window registration with PreFilter check
- Event handlers for app/window lifecycle
- Zombie cleanup

**Tests to write first:**
```lua
Test.describe('Tracker', function()
    Test.it('registers existing apps on start', ...)
    Test.it('skips non-GUI apps', ...)
    Test.it('skips blacklisted bundle IDs', ...)
    Test.it('creates window watchers', ...)
    Test.it('cleans up zombie apps', ...)
end)
```

**Critical verification:**
- Count watchers before/after start
- Verify watcher count is less than current implementation
- Verify no watchers for phantom windows (if PreFilter enabled)

**Exit criteria:** Tracker manages watchers correctly, watcher count reduced

---

#### Step 7: Manager (~150 lines)

**What to implement:**
- `Manager.getInstance()` - Singleton
- `:activate(wf)`, `:deactivate(wf)` - Instance lifecycle
- `:getContext()` - Current state
- `:refreshInstance(wf)` - Rebuild window set
- Callbacks from Tracker (onWindowCreated, etc.)

**Tests to write first:**
```lua
Test.describe('Manager', function()
    Test.it('starts tracker on first instance', ...)
    Test.it('stops tracker when last instance deactivates', ...)
    Test.it('refreshes windows on activate', ...)
end)
```

**Exit criteria:** Manager coordinates Tracker and instances correctly

---

#### Step 8: WindowFilter Class (~400 lines)

**What to implement:**
- All public API methods from Section 6.6
- Constructor variants (nil, true, false, string, table, function)
- Method chaining

**Tests to write first:**
- All tests from Section 9.4 (test_api_compat.lua)
- Additional tests for each public method

**Critical verification:**
```lua
-- API compatibility check
local old = hs.window.filter  -- Original
local new = require('window_filter_new')

-- Both should return same results
local oldWins = old.new():getWindows()
local newWins = new.new():getWindows()
-- Compare window IDs
```

**Exit criteria:** All API compatibility tests pass

---

#### Step 9: Default Filters + Module Functions (~100 lines)

**What to implement:**
- `windowfilter.default` - Lazy singleton with ignoreAlways
- `windowfilter.defaultCurrentSpace`
- `windowfilter.ignoreAlways`, `windowfilter.ignoreInDefaultFilter`
- Module-level functions (isGuiApp, focusEast/West/North/South)

**Verification:**
- `windowfilter.default:getWindows()` matches original behavior
- Direction methods work

**Exit criteria:** Module-level API complete

---

#### Step 10: Contract Verification + Performance (~50 lines of tests)

**Purpose**: The final gate. Run the Step 0 contract tests against the new implementation to verify API compatibility.

**What to do:**

1. **Run contract tests against new implementation:**
```lua
-- THE critical verification
local test_contract = require('test.test_contract')
local wf_new = require('window_filter_new')
local passed = test_contract(wf_new)
if not passed then
    error('CONTRACT TESTS FAILED - DO NOT PROCEED')
end
```

2. **Run performance benchmarks from Section 9.5**
3. **Memory testing (watcher count, Lua heap)**
4. **Edge case testing (rapid app launch/quit, space changes)**

**Performance verification:**
```lua
-- Must meet targets from Section 8
benchmark('getWindows warm', function() wf:getWindows() end)  -- < 50ms
-- Watcher count should be < 50% of original
```

**Contract verification:**
```lua
-- Compare behavior side-by-side
local old = hs.window.filter
local new = require('window_filter_new')

local oldWins = old.default:getWindows()
local newWins = new.default:getWindows()

-- Window IDs should match
local oldIds = {}
for _, w in ipairs(oldWins) do oldIds[w:id()] = true end
for _, w in ipairs(newWins) do
    if not oldIds[w:id()] then
        print('NEW has window not in OLD:', w:id(), w:title())
    end
end
```

**Exit criteria:**
- ALL contract tests from Step 0 pass against new implementation
- All performance targets met
- No behavioral regressions detected in side-by-side comparison

---

### 13.4 Session Management

Each step above is designed to be completable in a **single Claude session**. However, context may be limited, so:

1. **At session end**: Ensure code is in a working state (tests pass)
2. **At session start**: Read this plan document and relevant test files
3. **Resumption prompt**: "Continue implementing window_filter rewrite from Step N"

### 13.5 File Organization During Development

Development happens in the Hammerspoon source repository:

```
~/git.forks/hammerspoon/
├── extensions/window/
│   ├── window_filter.lua              # CURRENT implementation (backup before replacing)
│   ├── window_filter_new.lua          # NEW implementation (during development)
│   ├── test_window_filter.lua         # Contract tests (Step 0) - NEW FILE
│   ├── test_window.lua                # Existing window tests
│   ├── window.lua                     # Main window API
│   └── ...
├── scripts/
│   ├── build.sh                       # Main build script
│   └── github-ci-test.sh              # CI test runner
└── Hammerspoon.xcworkspace/           # Xcode workspace
```

**Development workflow:**
1. Create `window_filter_new.lua` alongside the existing `window_filter.lua`
2. Create `test_window_filter.lua` with contract tests
3. Develop and test the new implementation
4. When ready, backup `window_filter.lua` → `window_filter_old.lua`
5. Rename `window_filter_new.lua` → `window_filter.lua`
6. Run full test suite: `./scripts/build.sh test -e -d -s Release`

**Note:** `test_window_filter.lua` is the most important test file. It defines the behavioral contract that both the old and new implementations must satisfy.

### 13.6 Parallel Development Strategy

The new module should be developed **alongside** the existing one in the Hammerspoon repository:

1. Create `~/git.forks/hammerspoon/extensions/window/window_filter_new.lua`
2. Develop and test without affecting current `hs.window.filter`
3. Test the new implementation by temporarily loading it in Hammerspoon console:
   ```lua
   -- Load and test new implementation manually
   local wf_new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')
   ```
4. When ready, swap the files:
   ```bash
   cd ~/git.forks/hammerspoon/extensions/window/
   cp window_filter.lua window_filter_backup.lua
   cp window_filter_new.lua window_filter.lua
   ```
5. Run full test suite: `./scripts/build.sh test -e -d -s Release`

**Do NOT replace** `window_filter.lua` until:
- All contract tests pass against the new implementation
- Performance targets are met
- User explicitly requests the swap

### 13.7 API Compatibility Verification Script

Run this after each step that adds public API:

```lua
-- verify_api_compat.lua
local old = hs.window.filter
local new = require('window_filter_new')

local function checkAPI(name, oldObj, newObj)
    local missing = {}
    for k, v in pairs(oldObj) do
        if type(v) == 'function' and not newObj[k] then
            table.insert(missing, k)
        end
    end
    if #missing > 0 then
        print(name .. ' missing: ' .. table.concat(missing, ', '))
        return false
    end
    return true
end

-- Check module-level API
checkAPI('module', old, new)

-- Check instance methods
local oldWF = old.new(true)
local newWF = new.new(true)
checkAPI('instance', oldWF, newWF)

oldWF:delete()
newWF:delete()

print('API compatibility check complete')
```

### 13.8 Rollback Strategy

If a step introduces bugs:

1. Tests should catch it before proceeding
2. If bugs found later, git revert to last working commit
3. Each step should have its own commit with clear message:
   - "wf-rewrite: Step 1 - test framework and utilities"
   - "wf-rewrite: Step 2 - WindowInfo and AppInfo"
   - etc.

### 13.9 When to Ask for User Input

Claude should ask the user for input when:

1. **Design decisions** not covered in this plan
2. **API compatibility questions** (behavior differs from original)
3. **Performance trade-offs** (speed vs memory)
4. **Before making commits**
5. **Before proceeding to next step** (optional, user may prefer autonomous execution)

Claude should NOT ask for input when:

1. Implementation details within a step
2. Test structure
3. Code style (follow window.lua conventions)

### 13.10 Example Session Flow

**Session 1 (Step 0 - The Foundation):**
```
User: "Start implementing the window_filter rewrite"
Claude: [Reads this plan]
Claude: "Starting Step 0: Contract Tests. This is critical - I'll write tests
         against the current hs.window.filter to establish the behavioral contract."
Claude: [Creates test/test_framework.lua]
Claude: [Creates test/test_contract.lua with comprehensive tests]
Claude: [Runs tests against current hs.window.filter]
Claude: "Step 0 complete. 47 tests passed against current implementation.
         These tests now define what 'API compatible' means.
         Ready to proceed to Step 1?"
User: "Yes, continue"
Claude: [Proceeds to Step 1: Utilities]
```

**Session 2 (after context limit):**
```
User: "Continue window_filter rewrite from Step 3"
Claude: [Reads plan, reads test_contract.lua, reads existing code]
Claude: "Resuming at Step 3: FilterRules + Filter.
         Current state: Steps 0-2 complete.
         Contract tests (47) defined in test_contract.lua.
         Proceeding with Filter implementation..."
```

**Final Session (Step 10):**
```
User: "Continue to Step 10"
Claude: [Runs test_contract against new implementation]
Claude: "Running contract tests against window_filter_new..."
Claude: "47/47 tests passed. Contract verified."
Claude: [Runs performance benchmarks]
Claude: "getWindows avg: 23ms (target <50ms) ✓
         Watcher count: 48 vs 96 original (50% reduction) ✓"
Claude: "Step 10 complete. New implementation is API-compatible and
         meets all performance targets. Ready for user testing."
```

---

## Appendix A: Safe Call Utility

```lua
local function safeCall(fn, obj, ...)
    if not fn then return nil end
    local ok, result = pcall(fn, obj, ...)
    if ok then
        return result
    else
        log.df('safeCall failed: %s', tostring(result))
        return nil
    end
end

local function safeGetScreenId(hsWindow)
    local ok, screen = pcall(hsWindow.screen, hsWindow)
    if ok and screen then
        local ok2, id = pcall(screen.id, screen)
        if ok2 then return id end
    end
    return 0
end
```

---

## Appendix B: Sort Comparators

```lua
local SortComparators = {
    focusedLast = function(a, b)
        return (a.timeFocused or 0) > (b.timeFocused or 0)
    end,
    focused = function(a, b)
        return (a.timeFocused or 0) < (b.timeFocused or 0)
    end,
    createdLast = function(a, b)
        return (a.timeCreated or 0) > (b.timeCreated or 0)
    end,
    created = function(a, b)
        return (a.timeCreated or 0) < (b.timeCreated or 0)
    end,
}
```

---

## Appendix C: File Template

**Development file:** `~/git.forks/hammerspoon/extensions/window/window_filter_new.lua`
**Final location:** `~/git.forks/hammerspoon/extensions/window/window_filter.lua`

```lua
--- === hs.window.filter ===
---
--- Filter windows by application, title, location on screen and more,
--- and easily subscribe to events on these windows
---
--- This is a complete rewrite of the original hs.window.filter module,
--- maintaining full API compatibility while improving performance,
--- reliability, and maintainability.
---
--- @module hs.window.filter
--- @author Original: Hammerspoon Team, Rewrite: [Your Name]
--- @license MIT

----------------------------------------------------------------------
-- SECTION 1: IMPORTS AND CONSTANTS
----------------------------------------------------------------------

local pairs, ipairs, type, setmetatable = pairs, ipairs, type, setmetatable
local pcall, error, tostring = pcall, error, tostring
local tinsert, tremove, tsort = table.insert, table.remove, table.sort
local sformat, smatch, ssub = string.format, string.match, string.sub

local application = require('hs.application')
local uiwatcher = require('hs.uielement').watcher
local appwatcher = application.watcher
local timer = require('hs.timer')
local geometry = require('hs.geometry')
local screen = require('hs.screen')
local logger = require('hs.logger')

local log = logger.new('wfilter')
local windowfilter = {}

-- [Rest of implementation...]

return windowfilter
```
