# hs.window.filter Technical Reference

**Related Documents:**
- [Main Plan](window_filter-rewrite-plan.md) - Goals, architecture, phases
- [Implementation Guide](window_filter-rewrite-plan-for-claude.md) - Step-by-step implementation for Claude

---

## Data Structures

### Configuration

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

### PreFilter Configuration

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

### WindowInfo

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

### AppInfo

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

### Filter Rules

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

### Event Subscriptions

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

## Component Specifications

### PreFilter

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

### Filter (Pure Functions)

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

    -- Regions and Screens (only for visible windows)
    if windowInfo.isVisible then
        -- Regions: check if window covers or is inside region(s)
        if rule.allowRegions then
            if not Filter.matchesRegions(rule.allowRegions, windowInfo.frame) then
                return false, 'allowRegions mismatch'
            end
        end
        if rule.rejectRegions then
            if Filter.matchesRegions(rule.rejectRegions, windowInfo.frame) then
                return false, 'rejectRegions matched'
            end
        end
        -- Screens: resolved lazily at match time for reliability
        if rule.allowScreens then
            local allowedScreenIds = Filter.resolveScreens(rule.allowScreens)
            if not allowedScreenIds[windowInfo.screenId] then
                return false, 'screen not allowed'
            end
        end
        if rule.rejectScreens then
            local rejectedScreenIds = Filter.resolveScreens(rule.rejectScreens)
            if rejectedScreenIds[windowInfo.screenId] then
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

-- Helper: Match regions (50% overlap rule from current implementation)
function Filter.matchesRegions(regions, windowFrame)
    for _, region in ipairs(regions) do
        local intersection = windowFrame:intersect(region)
        if intersection.area > 0 then
            -- Window "covers" region if intersection >= 50% of region
            -- Window "is inside" region if intersection >= 50% of window
            local coverRatio = intersection.area / region.area
            local insideRatio = intersection.area / windowFrame.area
            if coverRatio >= 0.5 or insideRatio >= 0.5 then
                return true
            end
        end
    end
    return false
end

-- Helper: Resolve screen hints to screen IDs (lazy, for reliability with hot-plugging)
function Filter.resolveScreens(screenHints)
    local ids = {}
    if type(screenHints) ~= 'table' then screenHints = {screenHints} end
    for _, hint in ipairs(screenHints) do
        local scr = screen.find(hint)
        if scr then
            local ok, id = pcall(scr.id, scr)
            if ok and id then ids[id] = true end
        end
    end
    return ids
end
```

### Tracker

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

### Events

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

### Manager (Singleton)

**Purpose**: Coordinate tracker, maintain global context.

**Spaces Strategy (Eager Refresh for Reliability):**
- Use `hs.spaces.watcher` to detect space changes
- On space change, refresh all spaces-aware windowfilter instances immediately
- This matches current behavior and ensures `currentSpace=true` filters always reflect reality
- The `forceRefreshOnSpaceChange` module variable controls whether non-spaces-aware filters also refresh
- `switchedToSpace(n)` allows manual notification for numbered space shortcuts (performance optimization)
- Rationale: Lazy evaluation risks stale data; users expect immediate accuracy over marginal speed gains

**Screen Resolution Strategy (Lazy for Reliability):**
- Screen hints (`allowScreens`, `rejectScreens`) are resolved at filter match time, not configuration time
- This handles hot-plugging: screens can be connected/disconnected between configuration and filtering
- `Filter.resolveScreens()` is called during `Filter.matchesRule()`, not during `setAppFilter()`
- Rationale: Eager caching could return stale screen IDs; lazy resolution always reflects current state

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

### WindowFilter Class (Public API)

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

function WF:isWindowAllowed(hsWindow)
    -- Custom filter functions bypass pure Filter logic
    if self.customFilter then
        local ok, result = pcall(self.customFilter, hsWindow)
        return ok and result == true
    end

    -- Build WindowInfo and check against rules
    local windowInfo = WindowInfo.new(hsWindow)
    local context = Manager.getInstance():getContext()
    return Filter.matches(self.rules, windowInfo, context)
end

function WF:isAppAllowed(appname)
    -- Custom filter functions allow all apps (filtering happens at window level)
    if self.customFilter then
        return true
    end
    return self.rules.appRules[appname] ~= false
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

## API Compatibility Matrix

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
| `:setRegions(regions)`                                       | Full         |                       |
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

## Performance Targets

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

## Test Specifications

### Test Framework

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

### Internal Component Tests

Internal components (Filter, PreFilter, etc.) are tested **through the public API** rather than exposing internals via globals. This avoids polluting the global namespace and ensures tests reflect real usage.

**Testing strategy:**
- Create windowfilters with specific rules that exercise internal logic
- Use real or mock windows to verify filtering behavior
- Test edge cases through the public `isWindowAllowed()` and `getWindows()` methods

```lua
-- Filter logic tests via public API (added to test_window_filter.lua during Step 3)

function testFilterVisibleTrue()
  -- Tests Filter.matchesRule internally via public API
  hs.openConsole()
  local f = wf.new(true):setDefaultFilter({visible = true})
  local wins = f:getWindows()
  -- All returned windows should be visible
  for _, win in ipairs(wins) do
    assertTrue(win:isVisible())
  end
  f:delete()
  return success()
end

function testFilterRejectsInvisible()
  local f = wf.new(true):setDefaultFilter({visible = true})
  -- Minimized windows should be filtered out (they're not visible)
  local wins = f:getWindows()
  for _, win in ipairs(wins) do
    assertFalse(win:isMinimized())
  end
  f:delete()
  return success()
end

function testFilterAllowTitlesNumber()
  hs.openConsole()
  local f = wf.new(true):setDefaultFilter({allowTitles = 1})
  local wins = f:getWindows()
  -- All returned windows should have non-empty titles
  for _, win in ipairs(wins) do
    assertGreaterThan(0, #win:title())
  end
  f:delete()
  return success()
end

function testFilterAllowTitlesPattern()
  hs.openConsole()
  local f = wf.new(true):setDefaultFilter({allowTitles = 'Console'})
  local wins = f:getWindows()
  -- All returned windows should have "Console" in title
  for _, win in ipairs(wins) do
    assertTrue(win:title():match('Console') ~= nil)
  end
  f:delete()
  return success()
end

function testFilterAllowsAllRolesWithStar()
  -- Test allowRoles='*' via public API
  hs.openConsole()
  local f = wf.new(true):setDefaultFilter({allowRoles = '*'})
  -- Should return windows regardless of role
  local wins = f:getWindows()
  assertIsTable(wins)
  f:delete()
  return success()
end

function testFilterOverrideFalseRejectsAll()
  -- Test override=false rejects all windows
  local f = wf.new(true):setOverrideFilter(false)
  local wins = f:getWindows()
  assertIsEqual(0, #wins)
  f:delete()
  return success()
end
```

### PreFilter Tests

PreFilter behavior is tested indirectly through the public API and by observing which apps/windows are tracked.

```lua
-- PreFilter tests via public API (added to test_window_filter.lua during Step 4)

function testIgnoreAlwaysAppsRejected()
  -- Apps in ignoreAlways should be rejected by default filter
  local f = wf.new()  -- Uses default filter
  assertFalse(f:isAppAllowed('Spotlight'))
  assertFalse(f:isAppAllowed('Notification Center'))
  f:delete()
  return success()
end

function testIgnoreAlwaysAppsAllowedWithTrueFilter()
  -- new(true) should allow even ignored apps
  local f = wf.new(true)
  assertTrue(f:isAppAllowed('Spotlight'))
  assertTrue(f:isAppAllowed('Notification Center'))
  f:delete()
  return success()
end

function testPreFilterConfigurable()
  -- Verify preFilter table exists and is configurable
  assertIsTable(wf.ignoreAlways)
  -- Should be able to add to it
  local testApp = 'TestIgnoredApp12345'
  wf.ignoreAlways[testApp] = true
  local f = wf.new()
  assertFalse(f:isAppAllowed(testApp))
  wf.ignoreAlways[testApp] = nil  -- Clean up
  f:delete()
  return success()
end
```

### Performance Tests

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
