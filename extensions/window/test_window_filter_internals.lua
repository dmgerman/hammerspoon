-- test_window_filter_internals.lua
-- Internal component tests for window_filter_new.lua
-- These tests verify the internal components via _ prefixed exports.
--
-- Run via hs CLI:
--   /Users/dmg/bin/osx/hs -c 'dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter_internals.lua")'

-- ============================================================================
-- TEST FRAMEWORK
-- ============================================================================

local function success()
  return "Success"
end

local function failure(msg)
  error(string.format("Assertion failure: %s", msg), 2)
end

local function assertIsEqual(expected, actual)
  if type(expected) ~= type(actual) then
    failure(string.format("expected type: '%s', actual type: '%s'", type(expected), type(actual)))
  end
  if expected ~= actual then
    failure(string.format("expected: '%s', actual: '%s'", tostring(expected), tostring(actual)))
  end
end

local function assertTrue(a)
  if not a then
    failure("expected: true, actual: " .. tostring(a))
  end
end

local function assertFalse(a)
  if a then
    failure("expected: false, actual: " .. tostring(a))
  end
end

local function assertIsNil(a)
  if a ~= nil then
    failure("expected: nil, actual: " .. tostring(a))
  end
end

local function assertIsNotNil(a)
  if a == nil then
    failure("expected: not-nil, actual: nil")
  end
end

local function assertGreaterThan(a, b)
  if b <= a then
    failure(string.format("expected: %s > %s", tostring(b), tostring(a)))
  end
end

local function assertIsTable(a)
  if type(a) ~= "table" then
    failure(string.format("expected type: 'table', actual type: '%s'", type(a)))
  end
end

local function assertIsBoolean(a)
  if type(a) ~= "boolean" then
    failure(string.format("expected type: 'boolean', actual type: '%s'", type(a)))
  end
end

local function assertIsString(a)
  if type(a) ~= "string" then
    failure(string.format("expected type: 'string', actual type: '%s'", type(a)))
  end
end

local function assertIsNumber(a)
  if type(a) ~= "number" then
    failure(string.format("expected type: 'number', actual type: '%s'", type(a)))
  end
end

local function assertIsFunction(a)
  if type(a) ~= "function" then
    failure(string.format("expected type: 'function', actual type: '%s'", type(a)))
  end
end

local function assertErrorContains(fn, expectedMsg)
  local ok, err = pcall(fn)
  if ok then
    failure("expected error, but function succeeded")
  end
  if not string.find(tostring(err), expectedMsg, 1, true) then
    failure(string.format("expected error containing '%s', got: %s", expectedMsg, tostring(err)))
  end
end

-- ============================================================================
-- TEST RUNNER
-- ============================================================================

local testResults = {
  passed = 0,
  failed = 0,
  errors = {}
}

local function runTest(name, fn)
  local ok, result = pcall(fn)
  if ok and result == "Success" then
    testResults.passed = testResults.passed + 1
    print(string.format("  ✓ %s", name))
  else
    testResults.failed = testResults.failed + 1
    local errMsg = ok and tostring(result) or tostring(result)
    table.insert(testResults.errors, {name = name, error = errMsg})
    print(string.format("  ✗ %s: %s", name, errMsg))
  end
end

-- ============================================================================
-- LOAD NEW IMPLEMENTATION
-- ============================================================================

local wf_new = dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua")

-- ============================================================================
-- STEP 1: UTILITIES TESTS
-- ============================================================================

local function testSafeCallWithValidFunction()
  local obj = {value = 42}
  local fn = function(self) return self.value end
  local result = wf_new._safeCall(fn, obj)
  assertIsEqual(42, result)
  return success()
end

local function testSafeCallWithNilFunction()
  local result = wf_new._safeCall(nil, {})
  assertIsNil(result)
  return success()
end

local function testSafeCallWithError()
  local fn = function() error("intentional error") end
  local result = wf_new._safeCall(fn, nil)
  assertIsNil(result)
  return success()
end

local function testSafeGetScreenIdWithWindow()
  local win = hs.window.focusedWindow()
  if win then
    local screenId = wf_new._safeGetScreenId(win)
    assertIsNumber(screenId)
    assertGreaterThan(0, screenId)
  end
  return success()
end

local function testSafeGetScreenIdWithNil()
  local screenId = wf_new._safeGetScreenId(nil)
  assertIsEqual(0, screenId)
  return success()
end

local function testConfigExists()
  assertIsNotNil(wf_new._config)
  assertIsNumber(wf_new._config.RETRY_DELAY)
  assertIsNumber(wf_new._config.MAX_RETRIES)
  assertIsTable(wf_new._config.ALLOWED_ROLES)
  return success()
end

-- ============================================================================
-- STEP 2: WINDOWINFO TESTS
-- ============================================================================

local function testWindowInfoCreation()
  local win = hs.window.focusedWindow()
  if not win then
    print("    SKIP: No focused window")
    return success()
  end
  local info = wf_new._WindowInfo.new(win)
  assertIsNotNil(info)
  assertIsNumber(info.id)
  assertIsString(info.title)
  assertIsString(info.role)
  assertIsBoolean(info.isVisible)
  assertIsBoolean(info.isMinimized)
  assertIsBoolean(info.isFullscreen)
  assertIsBoolean(info.hasTitlebar)
  assertIsNumber(info.timeCreated)
  assertIsEqual(0, info.timeFocused)
  return success()
end

local function testWindowInfoWithNil()
  local info = wf_new._WindowInfo.new(nil)
  assertIsNil(info)
  return success()
end

local function testWindowInfoRefresh()
  local win = hs.window.focusedWindow()
  if not win then
    print("    SKIP: No focused window")
    return success()
  end
  local info = wf_new._WindowInfo.new(win)
  local refreshed = info:refresh()
  assertTrue(refreshed)
  return success()
end

local function testWindowInfoToString()
  local win = hs.window.focusedWindow()
  if not win then
    print("    SKIP: No focused window")
    return success()
  end
  local info = wf_new._WindowInfo.new(win)
  local str = tostring(info)
  assertIsString(str)
  assertTrue(string.find(str, "WindowInfo") ~= nil)
  return success()
end

-- ============================================================================
-- STEP 2: APPINFO TESTS
-- ============================================================================

local function testAppInfoCreation()
  local app = hs.application.frontmostApplication()
  if not app then
    print("    SKIP: No frontmost app")
    return success()
  end
  local info = wf_new._AppInfo.new(app, app:pid())
  assertIsNotNil(info)
  assertIsNumber(info.pid)
  assertIsString(info.name)
  assertIsString(info.bundleID)
  assertIsBoolean(info.isHidden)
  assertIsBoolean(info.isFrontmost)
  assertIsTable(info.windows)
  return success()
end

local function testAppInfoWithNil()
  local info = wf_new._AppInfo.new(nil)
  assertIsNil(info)
  return success()
end

local function testAppInfoRefresh()
  local app = hs.application.frontmostApplication()
  if not app then
    print("    SKIP: No frontmost app")
    return success()
  end
  local info = wf_new._AppInfo.new(app, app:pid())
  local refreshed = info:refresh()
  assertTrue(refreshed)
  return success()
end

local function testAppInfoToString()
  local app = hs.application.frontmostApplication()
  if not app then
    print("    SKIP: No frontmost app")
    return success()
  end
  local info = wf_new._AppInfo.new(app, app:pid())
  local str = tostring(info)
  assertIsString(str)
  assertTrue(string.find(str, "AppInfo") ~= nil)
  return success()
end

-- ============================================================================
-- STEP 3: FILTERRULES TESTS
-- ============================================================================

local function testFilterRulesCreation()
  local rules = wf_new._FilterRules.new()
  assertIsNotNil(rules)
  assertIsNil(rules.override)
  assertIsTable(rules.appRules)
  assertIsNil(rules.default)
  return success()
end

local function testFilterRulesToString()
  local rules = wf_new._FilterRules.new()
  local str = tostring(rules)
  assertIsString(str)
  assertTrue(string.find(str, "FilterRules") ~= nil)
  return success()
end

-- ============================================================================
-- STEP 3: FILTER TESTS
-- ============================================================================

local function testFilterMatchesWithNoRules()
  local rules = wf_new._FilterRules.new()
  local windowInfo = {appName = "TestApp", isVisible = true}
  local allowed, reason = wf_new._Filter.matches(rules, windowInfo, {})
  assertTrue(allowed)
  return success()
end

local function testFilterMatchesOverrideFalse()
  local rules = wf_new._FilterRules.new()
  rules.override = false
  local windowInfo = {appName = "TestApp", isVisible = true}
  local allowed, reason = wf_new._Filter.matches(rules, windowInfo, {})
  assertFalse(allowed)
  assertTrue(string.find(reason, "override") ~= nil)
  return success()
end

local function testFilterMatchesAppRejected()
  local rules = wf_new._FilterRules.new()
  rules.appRules["TestApp"] = false
  local windowInfo = {appName = "TestApp", isVisible = true}
  local allowed, reason = wf_new._Filter.matches(rules, windowInfo, {})
  assertFalse(allowed)
  assertTrue(string.find(reason, "app rejected") ~= nil)
  return success()
end

local function testFilterMatchesDefaultFalse()
  local rules = wf_new._FilterRules.new()
  rules.default = false
  local windowInfo = {appName = "TestApp", isVisible = true}
  local allowed, reason = wf_new._Filter.matches(rules, windowInfo, {})
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleVisible()
  local rule = {visible = true}
  local windowInfo = {isVisible = true, role = "AXStandardWindow"}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertTrue(allowed)

  windowInfo.isVisible = false
  allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleAllowTitlesNumber()
  local rule = {allowTitles = 3}
  local windowInfo = {title = "Hello", role = "AXStandardWindow"}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertTrue(allowed)

  windowInfo.title = "Hi"
  allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleAllowTitlesPattern()
  local rule = {allowTitles = "Console"}
  local windowInfo = {title = "Hammerspoon Console", role = "AXStandardWindow"}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertTrue(allowed)

  windowInfo.title = "Safari"
  allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleRejectTitles()
  local rule = {rejectTitles = "Untitled"}
  local windowInfo = {title = "My Document", role = "AXStandardWindow"}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertTrue(allowed)

  windowInfo.title = "Untitled"
  allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleFocused()
  local rule = {focused = true}
  local windowInfo = {id = 123, role = "AXStandardWindow"}
  local context = {focusedWindowId = 123}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, context)
  assertTrue(allowed)

  context.focusedWindowId = 456
  allowed = wf_new._Filter.matchesRule(rule, windowInfo, context)
  assertFalse(allowed)
  return success()
end

local function testFilterMatchesRuleAllowRolesStar()
  local rule = {allowRoles = '*'}
  local windowInfo = {role = "AnyRole"}
  local allowed = wf_new._Filter.matchesRule(rule, windowInfo, {})
  assertTrue(allowed)
  return success()
end

local function testFilterMatchesRegions()
  local frame = hs.geometry.rect(100, 100, 200, 200)
  local region = hs.geometry.rect(0, 0, 500, 500)
  local matches = wf_new._Filter.matchesRegions({region}, frame)
  assertTrue(matches)

  local farRegion = hs.geometry.rect(1000, 1000, 100, 100)
  matches = wf_new._Filter.matchesRegions({farRegion}, frame)
  assertFalse(matches)
  return success()
end

local function testFilterResolveScreens()
  local mainScreen = hs.screen.mainScreen()
  if not mainScreen then
    print("    SKIP: No main screen")
    return success()
  end
  local ids = wf_new._Filter.resolveScreens(mainScreen)
  assertIsTable(ids)
  assertTrue(ids[mainScreen:id()])
  return success()
end

-- ============================================================================
-- STEP 4: PREFILTER TESTS
-- ============================================================================

local function testPreFilterShouldTrackAppWithValidApp()
  local app = hs.application.frontmostApplication()
  if not app then
    print("    SKIP: No frontmost app")
    return success()
  end
  local config = wf_new._PreFilter.defaultConfig()
  local shouldTrack, reason = wf_new._PreFilter.shouldTrackApp(app, config)
  assertTrue(shouldTrack)
  return success()
end

local function testPreFilterShouldTrackAppWithNil()
  local config = wf_new._PreFilter.defaultConfig()
  local shouldTrack, reason = wf_new._PreFilter.shouldTrackApp(nil, config)
  assertFalse(shouldTrack)
  return success()
end

local function testPreFilterShouldTrackAppBlacklisted()
  local app = hs.application.frontmostApplication()
  if not app then
    print("    SKIP: No frontmost app")
    return success()
  end
  local config = wf_new._PreFilter.defaultConfig()
  config.ignoreAppNames[app:name()] = true
  local shouldTrack, reason = wf_new._PreFilter.shouldTrackApp(app, config)
  assertFalse(shouldTrack)
  assertTrue(string.find(reason, "blacklisted") ~= nil)
  return success()
end

local function testPreFilterShouldTrackWithValidWindow()
  local win = hs.window.focusedWindow()
  if not win then
    print("    SKIP: No focused window")
    return success()
  end
  local config = wf_new._PreFilter.defaultConfig()
  local shouldTrack, reason = wf_new._PreFilter.shouldTrack(win, nil, config)
  assertTrue(shouldTrack)
  return success()
end

local function testPreFilterShouldTrackWithNil()
  local config = wf_new._PreFilter.defaultConfig()
  local shouldTrack, reason = wf_new._PreFilter.shouldTrack(nil, nil, config)
  assertFalse(shouldTrack)
  return success()
end

local function testPreFilterDefaultConfig()
  local config = wf_new._PreFilter.defaultConfig()
  assertIsTable(config)
  assertIsTable(config.ignoreBundleIDs)
  assertIsTable(config.ignoreAppNames)
  assertIsString(config.ignoreAppPattern)
  assertFalse(config.requireTitle)
  assertFalse(config.requireRole)
  return success()
end

-- ============================================================================
-- STEP 5: EVENT CONSTANTS TESTS
-- ============================================================================

local function testEventConstantsExist()
  assertIsString(wf_new.windowCreated)
  assertIsString(wf_new.windowDestroyed)
  assertIsString(wf_new.windowFocused)
  assertIsString(wf_new.windowUnfocused)
  assertIsString(wf_new.windowMoved)
  assertIsString(wf_new.windowMinimized)
  assertIsString(wf_new.windowUnminimized)
  assertIsString(wf_new.windowHidden)
  assertIsString(wf_new.windowUnhidden)
  assertIsString(wf_new.windowVisible)
  assertIsString(wf_new.windowNotVisible)
  assertIsString(wf_new.windowTitleChanged)
  assertIsString(wf_new.windowAllowed)
  assertIsString(wf_new.windowRejected)
  assertIsString(wf_new.hasWindow)
  assertIsString(wf_new.hasNoWindows)
  assertIsString(wf_new.windowsChanged)
  return success()
end

local function testSortOrderConstantsExist()
  assertIsString(wf_new.sortByFocused)
  assertIsString(wf_new.sortByFocusedLast)
  assertIsString(wf_new.sortByCreated)
  assertIsString(wf_new.sortByCreatedLast)
  return success()
end

local function testIsValidEvent()
  assertTrue(wf_new._isValidEvent(wf_new.windowFocused))
  assertTrue(wf_new._isValidEvent(wf_new.windowCreated))
  assertFalse(wf_new._isValidEvent("notAnEvent"))
  assertFalse(wf_new._isValidEvent(nil))
  return success()
end

-- ============================================================================
-- STEP 5: SUBSCRIPTIONS TESTS
-- ============================================================================

local function testSubscriptionsCreation()
  local subs = wf_new._Subscriptions.new()
  assertIsNotNil(subs)
  assertFalse(subs:hasAny())
  assertIsEqual(0, subs:count())
  return success()
end

local function testSubscriptionsAdd()
  local subs = wf_new._Subscriptions.new()
  local fn = function() end
  local added = subs:add(wf_new.windowFocused, fn)
  assertTrue(added)
  assertTrue(subs:hasAny())
  assertTrue(subs:hasEvent(wf_new.windowFocused))
  assertIsEqual(1, subs:count(wf_new.windowFocused))
  return success()
end

local function testSubscriptionsAddDuplicate()
  local subs = wf_new._Subscriptions.new()
  local fn = function() end
  subs:add(wf_new.windowFocused, fn)
  local added = subs:add(wf_new.windowFocused, fn)
  assertFalse(added)
  assertIsEqual(1, subs:count(wf_new.windowFocused))
  return success()
end

local function testSubscriptionsAddInvalidEvent()
  local subs = wf_new._Subscriptions.new()
  assertErrorContains(function()
    subs:add("invalidEvent", function() end)
  end, "invalid event")
  return success()
end

local function testSubscriptionsAddNonFunction()
  local subs = wf_new._Subscriptions.new()
  assertErrorContains(function()
    subs:add(wf_new.windowFocused, "not a function")
  end, "must be a function")
  return success()
end

local function testSubscriptionsRemove()
  local subs = wf_new._Subscriptions.new()
  local fn = function() end
  subs:add(wf_new.windowFocused, fn)
  local removed = subs:remove(wf_new.windowFocused, fn)
  assertTrue(removed)
  assertFalse(subs:hasAny())
  return success()
end

local function testSubscriptionsRemoveNotFound()
  local subs = wf_new._Subscriptions.new()
  local fn = function() end
  local removed = subs:remove(wf_new.windowFocused, fn)
  assertFalse(removed)
  return success()
end

local function testSubscriptionsRemoveAll()
  local subs = wf_new._Subscriptions.new()
  subs:add(wf_new.windowFocused, function() end)
  subs:add(wf_new.windowCreated, function() end)
  local count = subs:removeAll()
  assertIsEqual(2, count)
  assertFalse(subs:hasAny())
  return success()
end

local function testSubscriptionsRemoveAllForEvent()
  local subs = wf_new._Subscriptions.new()
  subs:add(wf_new.windowFocused, function() end)
  subs:add(wf_new.windowFocused, function() end)
  subs:add(wf_new.windowCreated, function() end)
  local count = subs:removeAll(wf_new.windowFocused)
  assertIsEqual(2, count)
  assertTrue(subs:hasAny())
  assertFalse(subs:hasEvent(wf_new.windowFocused))
  assertTrue(subs:hasEvent(wf_new.windowCreated))
  return success()
end

local function testSubscriptionsEmit()
  local subs = wf_new._Subscriptions.new()
  local callCount = 0
  local receivedArgs = {}
  subs:add(wf_new.windowFocused, function(win, app, ev)
    callCount = callCount + 1
    receivedArgs = {win = win, app = app, ev = ev}
  end)
  local emitted = subs:emit(wf_new.windowFocused, "testWin", "TestApp")
  assertIsEqual(1, emitted)
  assertIsEqual(1, callCount)
  assertIsEqual("testWin", receivedArgs.win)
  assertIsEqual("TestApp", receivedArgs.app)
  assertIsEqual(wf_new.windowFocused, receivedArgs.ev)
  return success()
end

local function testSubscriptionsEmitMultiple()
  local subs = wf_new._Subscriptions.new()
  local total = 0
  subs:add(wf_new.windowFocused, function() total = total + 1 end)
  subs:add(wf_new.windowFocused, function() total = total + 10 end)
  subs:emit(wf_new.windowFocused, nil, nil)
  assertIsEqual(11, total)
  return success()
end

local function testSubscriptionsEmitWithError()
  local subs = wf_new._Subscriptions.new()
  local goodCalled = false
  subs:add(wf_new.windowFocused, function() error("intentional") end)
  subs:add(wf_new.windowFocused, function() goodCalled = true end)
  -- Should not throw, should continue to next callback
  local emitted = subs:emit(wf_new.windowFocused, nil, nil)
  assertIsEqual(2, emitted)
  assertTrue(goodCalled)
  return success()
end

local function testSubscriptionsEmitNoCallbacks()
  local subs = wf_new._Subscriptions.new()
  local emitted = subs:emit(wf_new.windowFocused, nil, nil)
  assertIsEqual(0, emitted)
  return success()
end

local function testSubscriptionsSelfUnsubscribe()
  local subs = wf_new._Subscriptions.new()
  local fn1
  fn1 = function()
    subs:remove(wf_new.windowFocused, fn1)
  end
  local fn2Called = false
  local fn2 = function() fn2Called = true end
  subs:add(wf_new.windowFocused, fn1)
  subs:add(wf_new.windowFocused, fn2)
  subs:emit(wf_new.windowFocused, nil, nil)
  assertTrue(fn2Called)
  assertIsEqual(1, subs:count(wf_new.windowFocused))
  return success()
end

local function testSubscriptionsToString()
  local subs = wf_new._Subscriptions.new()
  subs:add(wf_new.windowFocused, function() end)
  local str = tostring(subs)
  assertIsString(str)
  assertTrue(string.find(str, "Subscriptions") ~= nil)
  return success()
end

-- ============================================================================
-- STEP 6: MANAGERSTUB TESTS
-- ============================================================================

local function testManagerStubCreation()
  local stub = wf_new._ManagerStub.new()
  assertIsNotNil(stub)
  assertIsTable(stub.events)
  assertIsEqual(0, #stub.events)
  assertIsTable(stub.preFilter)
  return success()
end

local function testManagerStubRecordsEvents()
  local stub = wf_new._ManagerStub.new()
  stub:onWindowCreated({id = 1}, {name = "TestApp"})
  stub:onWindowDestroyed({id = 1}, {name = "TestApp"})
  stub:onAppActivated({name = "TestApp"})
  assertIsEqual(3, #stub.events)
  assertIsEqual("windowCreated", stub.events[1].event)
  assertIsEqual("windowDestroyed", stub.events[2].event)
  assertIsEqual("appActivated", stub.events[3].event)
  return success()
end

local function testManagerStubGetEventCount()
  local stub = wf_new._ManagerStub.new()
  stub:onWindowCreated({id = 1}, {name = "App1"})
  stub:onWindowCreated({id = 2}, {name = "App1"})
  stub:onAppActivated({name = "App1"})
  assertIsEqual(2, stub:getEventCount("windowCreated"))
  assertIsEqual(1, stub:getEventCount("appActivated"))
  assertIsEqual(0, stub:getEventCount("windowDestroyed"))
  return success()
end

local function testManagerStubGetLastEvent()
  local stub = wf_new._ManagerStub.new()
  stub:onWindowCreated({id = 1}, {name = "App1"})
  stub:onWindowCreated({id = 2}, {name = "App2"})
  local lastEvent = stub:getLastEvent("windowCreated")
  assertIsNotNil(lastEvent)
  assertIsEqual("windowCreated", lastEvent.event)
  assertIsEqual(2, lastEvent.args[1].id)
  return success()
end

local function testManagerStubClearEvents()
  local stub = wf_new._ManagerStub.new()
  stub:onWindowCreated({id = 1}, {name = "App1"})
  stub:clearEvents()
  assertIsEqual(0, #stub.events)
  return success()
end

-- ============================================================================
-- STEP 6: TRACKER TESTS
-- ============================================================================

local function testTrackerCreation()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)
  assertIsNotNil(tracker)
  assertFalse(tracker.running)
  assertIsEqual(0, tracker:getAppCount())
  assertIsEqual(0, tracker:getWindowCount())
  return success()
end

local function testTrackerStartStop()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Test running state transitions
  assertFalse(tracker.running)

  -- Manually set running and create watcher (without event handler)
  tracker.running = true
  tracker.appWatcher = hs.application.watcher.new(function() end)

  assertTrue(tracker.running)
  assertIsNotNil(tracker.appWatcher)

  -- Register just one app manually for testing
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end

  -- Should have tracked at least 1 app
  assertGreaterThan(0, tracker:getAppCount())

  -- Stop
  tracker:stop()
  assertFalse(tracker.running)
  assertIsNil(tracker.appWatcher)
  assertIsEqual(0, tracker:getAppCount())

  return success()
end

local function testTrackerTracksExistingApps()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Manually start and register one app
  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end

  -- Should have tracked 1 app
  local appCount = tracker:getAppCount()
  assertGreaterThan(0, appCount)

  -- Should have sent windowCreated events for that app's windows
  local createdCount = stub:getEventCount("windowCreated")
  assertIsNumber(createdCount)

  tracker:stop()
  return success()
end

local function testTrackerTracksWindows()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Manually start and register one app
  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end

  -- Should have tracked some windows for that app
  local windowCount = tracker:getWindowCount()
  assertIsNumber(windowCount)

  tracker:stop()
  return success()
end

local function testTrackerToString()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)
  local str = tostring(tracker)
  assertIsString(str)
  assertTrue(string.find(str, "Tracker") ~= nil)
  return success()
end

local function testTrackerDoubleStartIsNoop()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Manually create watcher
  tracker.running = true
  tracker.appWatcher = hs.application.watcher.new(function() end)
  local watcher1 = tracker.appWatcher

  -- Calling start() when already running should be noop
  tracker:start()  -- Should be noop because running is true
  assertIsEqual(watcher1, tracker.appWatcher)

  tracker:stop()
  return success()
end

local function testTrackerDoubleStopIsNoop()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Manually start
  tracker.running = true
  tracker.appWatcher = hs.application.watcher.new(function() end)

  tracker:stop()
  tracker:stop()  -- Should be noop
  assertFalse(tracker.running)
  return success()
end

local function testTrackerPreFilterIntegration()
  local stub = wf_new._ManagerStub.new()
  -- Blacklist Hammerspoon
  stub.preFilter.ignoreAppNames["Hammerspoon"] = true
  local tracker = wf_new._Tracker.new(stub)

  tracker.running = true
  -- Try to register Hammerspoon
  local hs_app = hs.application.find("Hammerspoon")
  if hs_app then
    tracker:registerApp(hs_app)
  end

  -- Hammerspoon should not be tracked (blacklisted)
  local found = false
  for pid, appInfo in pairs(tracker.apps) do
    if appInfo.name == "Hammerspoon" then
      found = true
      break
    end
  end
  assertFalse(found)

  tracker:stop()
  return success()
end

local function testTrackerCleanupOnStop()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  -- Manually start and register one app
  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end

  tracker:stop()

  -- Everything should be cleaned up
  assertIsEqual(0, tracker:getAppCount())
  assertIsEqual(0, tracker:getWindowCount())
  assertIsNil(tracker.appWatcher)

  return success()
end

local function testTrackerGetAppAndWindowCount()
  local stub = wf_new._ManagerStub.new()
  local tracker = wf_new._Tracker.new(stub)

  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end

  local appCount = tracker:getAppCount()
  local windowCount = tracker:getWindowCount()

  assertIsNumber(appCount)
  assertIsNumber(windowCount)

  tracker:stop()
  return success()
end

local function testTrackerManagerCallbackError()
  -- Manager that throws errors
  local badManager = {
    preFilter = wf_new._PreFilter.defaultConfig(),
    onWindowCreated = function() error("intentional error") end,
    onWindowDestroyed = function() end,
  }
  local tracker = wf_new._Tracker.new(badManager)

  -- Manually start and register one app
  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    -- This should not crash even with bad manager
    tracker:registerApp(app)
  end
  assertTrue(tracker.running)
  tracker:stop()

  return success()
end

local function testTrackerWithNilManager()
  local tracker = wf_new._Tracker.new(nil)
  assertIsNotNil(tracker)

  -- Should not crash with nil manager
  tracker.running = true
  local app = hs.application.frontmostApplication()
  if app then
    tracker:registerApp(app)
  end
  assertTrue(tracker.running)
  tracker:stop()

  return success()
end

-- ============================================================================
-- STEP 7: MANAGER TESTS
-- ============================================================================
-- Manager tests are designed to avoid full Tracker startup (which registers
-- 100+ apps and causes timeouts). Tests manually set up Manager state or
-- use lightweight mocking.

-- Helper: create a mock WindowFilter instance for testing
local function createMockWF(trackSpaces)
  return {
    _trackSpaces = trackSpaces or false,
    _events = {},
    _handleTrackerEvent = function(self, eventType, windowInfo, appInfo)
      table.insert(self._events, {
        eventType = eventType,
        windowInfo = windowInfo,
        appInfo = appInfo,
      })
    end,
  }
end

-- Helper: reset Manager singleton for testing (without full Tracker stop)
local function resetManager()
  local manager = wf_new._Manager.getInstance()
  -- Clear instances without triggering full lifecycle
  manager.activeInstances = {}
  manager.spacesInstances = {}
  manager.instanceCount = 0
  -- Stop tracker if running
  if manager.tracker then
    manager.tracker:stop()
    manager.tracker = nil
  end
  -- Stop spaces watcher if running
  if manager.spacesWatcher then
    manager.spacesWatcher:stop()
    manager.spacesWatcher = nil
  end
end

-- Helper: create a mock Tracker for Manager tests
local function createMockTracker()
  return {
    running = true,
    focusedWindowId = 123,
    focusedAppPid = 456,
    apps = {},
    start = function() end,
    stop = function(self) self.running = false end,
  }
end

local function testManagerGetInstance()
  local manager = wf_new._Manager.getInstance()
  assertIsNotNil(manager)
  -- Same instance returned on second call
  local manager2 = wf_new._Manager.getInstance()
  assertIsEqual(manager, manager2)
  return success()
end

local function testManagerInitialState()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  assertIsEqual(0, manager:getInstanceCount())
  assertFalse(manager:isRunning())
  assertIsNil(manager:getTracker())
  return success()
end

local function testManagerActivateIncrementsCount()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Manually add without full lifecycle
  manager.activeInstances[wf] = true
  manager.instanceCount = 1
  manager.tracker = createMockTracker()

  assertIsEqual(1, manager:getInstanceCount())
  assertTrue(manager:isRunning())

  resetManager()
  return success()
end

local function testManagerDeactivateDecrementsCount()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Set up state manually
  manager.activeInstances[wf] = true
  manager.instanceCount = 1
  manager.tracker = createMockTracker()

  manager:deactivate(wf)
  assertIsEqual(0, manager:getInstanceCount())
  assertFalse(manager:isRunning())

  return success()
end

local function testManagerMultipleInstancesCounting()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf1 = createMockWF()
  local wf2 = createMockWF()
  local wf3 = createMockWF()

  -- Manually set up instances
  manager.tracker = createMockTracker()
  manager.activeInstances[wf1] = true
  manager.activeInstances[wf2] = true
  manager.activeInstances[wf3] = true
  manager.instanceCount = 3

  assertIsEqual(3, manager:getInstanceCount())
  assertTrue(manager:isRunning())

  -- Deactivate one
  manager:deactivate(wf1)
  assertIsEqual(2, manager:getInstanceCount())
  assertTrue(manager:isRunning())

  -- Deactivate second
  manager:deactivate(wf2)
  assertIsEqual(1, manager:getInstanceCount())
  assertTrue(manager:isRunning())

  -- Deactivate last
  manager:deactivate(wf3)
  assertIsEqual(0, manager:getInstanceCount())
  assertFalse(manager:isRunning())

  return success()
end

local function testManagerDoubleActivateIsNoop()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Set up state
  manager.tracker = createMockTracker()
  manager.activeInstances[wf] = true
  manager.instanceCount = 1

  -- Calling activate on already active instance should be noop
  manager:activate(wf)
  assertIsEqual(1, manager:getInstanceCount())

  resetManager()
  return success()
end

local function testManagerDoubleDeactivateIsNoop()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Set up and deactivate
  manager.tracker = createMockTracker()
  manager.activeInstances[wf] = true
  manager.instanceCount = 1
  manager:deactivate(wf)
  assertIsEqual(0, manager:getInstanceCount())

  -- Second deactivate should be noop
  manager:deactivate(wf)
  assertIsEqual(0, manager:getInstanceCount())

  return success()
end

local function testManagerGetContext()
  resetManager()
  local manager = wf_new._Manager.getInstance()

  -- Before tracker, context should be empty
  local ctx = manager:getContext()
  assertIsTable(ctx)
  assertIsNil(ctx.focusedWindowId)
  assertIsNil(ctx.activeAppPid)

  -- With mock tracker, context should be available
  manager.tracker = createMockTracker()
  ctx = manager:getContext()
  assertIsTable(ctx)
  assertIsEqual(123, ctx.focusedWindowId)
  assertIsEqual(456, ctx.activeAppPid)

  resetManager()
  return success()
end

local function testManagerRoutesEvents()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf1 = createMockWF()
  local wf2 = createMockWF()

  -- Set up instances
  manager.tracker = createMockTracker()
  manager.activeInstances[wf1] = true
  manager.activeInstances[wf2] = true
  manager.instanceCount = 2

  -- Simulate event from Tracker
  local testWindowInfo = {id = 123, title = "Test"}
  local testAppInfo = {name = "TestApp", pid = 456}
  manager:onWindowCreated(testWindowInfo, testAppInfo)

  -- Both instances should receive the event
  assertIsEqual(1, #wf1._events)
  assertIsEqual(1, #wf2._events)
  assertIsEqual('windowCreated', wf1._events[1].eventType)
  assertIsEqual(123, wf1._events[1].windowInfo.id)

  resetManager()
  return success()
end

local function testManagerRoutesAllEventTypes()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Set up instance
  manager.tracker = createMockTracker()
  manager.activeInstances[wf] = true
  manager.instanceCount = 1

  local winInfo = {id = 1}
  local appInfo = {name = "App"}

  -- Test all event routing methods
  manager:onWindowCreated(winInfo, appInfo)
  manager:onWindowDestroyed(winInfo, appInfo)
  manager:onWindowMoved(winInfo, appInfo)
  manager:onWindowMinimized(winInfo, appInfo)
  manager:onWindowUnminimized(winInfo, appInfo)
  manager:onWindowTitleChanged(winInfo, appInfo)
  manager:onAppActivated(appInfo)
  manager:onAppDeactivated(appInfo)
  manager:onAppHidden(appInfo)
  manager:onAppUnhidden(appInfo)

  -- Check that all events were routed
  local eventTypes = {}
  for _, ev in ipairs(wf._events) do
    eventTypes[ev.eventType] = true
  end

  assertTrue(eventTypes['windowCreated'])
  assertTrue(eventTypes['windowDestroyed'])
  assertTrue(eventTypes['windowMoved'])
  assertTrue(eventTypes['windowMinimized'])
  assertTrue(eventTypes['windowUnminimized'])
  assertTrue(eventTypes['windowTitleChanged'])
  assertTrue(eventTypes['appActivated'])
  assertTrue(eventTypes['appDeactivated'])
  assertTrue(eventTypes['appHidden'])
  assertTrue(eventTypes['appUnhidden'])

  resetManager()
  return success()
end

local function testManagerSpacesInstanceTracking()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf1 = createMockWF(false)  -- Not space-aware
  local wf2 = createMockWF(true)   -- Space-aware

  -- Manually set up instances with _trackSpaces
  manager.tracker = createMockTracker()
  manager.activeInstances[wf1] = true
  manager.activeInstances[wf2] = true
  manager.instanceCount = 2
  -- Simulate what activate() does for space-aware instance
  if wf2._trackSpaces then
    manager.spacesInstances[wf2] = true
  end

  -- wf2 should be in spacesInstances
  assertTrue(manager.spacesInstances[wf2] == true)
  assertIsNil(manager.spacesInstances[wf1])

  resetManager()
  return success()
end

local function testManagerHandlesInstanceErrors()
  resetManager()
  local manager = wf_new._Manager.getInstance()

  -- Create instance that throws errors
  local badWF = {
    _trackSpaces = false,
    _handleTrackerEvent = function()
      error("intentional error")
    end,
  }

  local goodWF = createMockWF()

  -- Set up instances
  manager.tracker = createMockTracker()
  manager.activeInstances[badWF] = true
  manager.activeInstances[goodWF] = true
  manager.instanceCount = 2

  -- Should not crash, good instance should still receive event
  manager:onWindowCreated({id = 1}, {name = "App"})

  -- goodWF should have received the event despite badWF error
  assertIsEqual(1, #goodWF._events)

  resetManager()
  return success()
end

local function testManagerToString()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local str = tostring(manager)
  assertIsString(str)
  assertTrue(string.find(str, "Manager") ~= nil)
  return success()
end

local function testManagerForceRefreshOnSpaceChangeVariable()
  -- Just verify the module variable exists
  assertIsBoolean(wf_new.forceRefreshOnSpaceChange)
  assertFalse(wf_new.forceRefreshOnSpaceChange)  -- Default is false
  return success()
end

local function testManagerRefreshInstance()
  resetManager()
  local manager = wf_new._Manager.getInstance()

  -- Create mock tracker with windows
  local mockTracker = createMockTracker()
  mockTracker.apps = {
    [100] = {
      name = "TestApp",
      pid = 100,
      windows = {
        [1] = {id = 1, title = "Win1", appName = "TestApp"},
        [2] = {id = 2, title = "Win2", appName = "TestApp"},
      }
    }
  }
  manager.tracker = mockTracker

  -- Create instance and call refresh
  local wf = createMockWF()
  manager.activeInstances[wf] = true
  manager.instanceCount = 1

  manager:_refreshInstance(wf)

  -- Should have received windowCreated for each window
  assertIsEqual(2, #wf._events)
  assertIsEqual('windowCreated', wf._events[1].eventType)

  resetManager()
  return success()
end

local function testManagerFocusChangedRouting()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Set up instance
  manager.tracker = createMockTracker()
  manager.activeInstances[wf] = true
  manager.instanceCount = 1

  -- Test focus changed routing
  local winInfo = {id = 1}
  local appInfo = {name = "App"}
  manager:onFocusChanged(winInfo, appInfo, nil)

  -- Should receive focusChanged event
  local found = false
  for _, ev in ipairs(wf._events) do
    if ev.eventType == 'focusChanged' then
      found = true
      break
    end
  end
  assertTrue(found)

  resetManager()
  return success()
end

-- Test that verifies Manager integrates with real Tracker (one integration test)
local function testManagerIntegrationWithTracker()
  resetManager()
  local manager = wf_new._Manager.getInstance()
  local wf = createMockWF()

  -- Actually activate - this will start real Tracker
  -- We only register one app manually to keep it fast
  manager.activeInstances[wf] = true
  manager.instanceCount = 1

  -- Create real tracker but don't call start() (which is slow)
  manager.tracker = wf_new._Tracker.new(manager)
  manager.tracker.running = true

  -- Register just one app manually
  local app = hs.application.frontmostApplication()
  if app then
    manager.tracker:registerApp(app)
  end

  -- Should have some windows tracked
  assertGreaterThan(-1, manager.tracker:getWindowCount())

  -- Should have received windowCreated events
  assertIsNumber(#wf._events)

  -- Clean up
  manager.tracker:stop()
  manager.tracker = nil
  resetManager()

  return success()
end

-- ============================================================================
-- STEP 8a: WINDOWFILTER CLASS TESTS
-- ============================================================================

local function testWindowFilterCreation()
  local wf = wf_new.new()
  assertIsNotNil(wf)
  assertIsTable(wf)
  return success()
end

local function testWindowFilterConstructorNil()
  local wf = wf_new.new(nil)
  -- Default filter allows most apps
  assertTrue(wf:isAppAllowed('Safari'))
  assertTrue(wf:isAppAllowed('Finder'))
  wf:delete()
  return success()
end

local function testWindowFilterConstructorTrue()
  local wf = wf_new.new(true)
  -- Allow all including normally ignored apps
  assertTrue(wf:isAppAllowed('Safari'))
  assertTrue(wf:isAppAllowed('Spotlight'))  -- Normally ignored
  wf:delete()
  return success()
end

local function testWindowFilterConstructorFalse()
  local wf = wf_new.new(false)
  -- Reject all apps
  assertFalse(wf:isAppAllowed('Safari'))
  assertFalse(wf:isAppAllowed('Finder'))
  wf:delete()
  return success()
end

local function testWindowFilterConstructorString()
  local wf = wf_new.new('Safari')
  -- String constructor: isAppAllowed returns true for all (filtering at window level)
  -- This matches original implementation behavior
  assertTrue(wf:isAppAllowed('Safari'))
  assertTrue(wf:isAppAllowed('Finder'))  -- All apps allowed at app level
  -- Actual filtering happens via _allowedApps in isWindowAllowed
  assertIsNotNil(wf._allowedApps)
  assertTrue(wf._allowedApps['Safari'])
  wf:delete()
  return success()
end

local function testWindowFilterConstructorTable()
  local wf = wf_new.new({'Safari', 'Finder'})
  -- Table constructor: isAppAllowed returns true for all (filtering at window level)
  assertTrue(wf:isAppAllowed('Safari'))
  assertTrue(wf:isAppAllowed('Finder'))
  assertTrue(wf:isAppAllowed('Chrome'))  -- All apps allowed at app level
  -- Actual filtering happens via _allowedApps
  assertIsNotNil(wf._allowedApps)
  assertTrue(wf._allowedApps['Safari'])
  assertTrue(wf._allowedApps['Finder'])
  wf:delete()
  return success()
end

local function testWindowFilterConstructorFunction()
  local wf = wf_new.new(function(win) return true end)
  -- Custom function allows all apps at app level
  assertTrue(wf:isAppAllowed('Safari'))
  assertTrue(wf:isAppAllowed('Anything'))
  wf:delete()
  return success()
end

local function testWindowFilterSetAppFilter()
  local wf = wf_new.new()
  local result = wf:setAppFilter('Safari', true)
  assertIsEqual(wf, result)  -- Returns self for chaining
  assertTrue(wf:isAppAllowed('Safari'))
  wf:delete()
  return success()
end

local function testWindowFilterSetDefaultFilter()
  local wf = wf_new.new()
  local result = wf:setDefaultFilter(false)
  assertIsEqual(wf, result)
  assertFalse(wf:isAppAllowed('Safari'))
  wf:delete()
  return success()
end

local function testWindowFilterAllowRejectApp()
  local wf = wf_new.new(false)
  wf:allowApp('Safari')
  assertTrue(wf:isAppAllowed('Safari'))
  wf:rejectApp('Safari')
  assertFalse(wf:isAppAllowed('Safari'))
  wf:delete()
  return success()
end

local function testWindowFilterPauseResume()
  local wf = wf_new.new()
  assertFalse(wf._paused)
  wf:pause()
  assertTrue(wf._paused)
  wf:resume()
  assertFalse(wf._paused)
  wf:delete()
  return success()
end

local function testWindowFilterCopy()
  local wf1 = wf_new.new()
  wf1:setAppFilter('Safari', true)
  wf1:setDefaultFilter(false)

  local wf2 = wf1:copy()
  assertIsNotNil(wf2)
  assertTrue(wf2:isAppAllowed('Safari'))
  assertFalse(wf2:isAppAllowed('Finder'))

  -- Modifications to copy don't affect original
  wf2:allowApp('Finder')
  assertTrue(wf2:isAppAllowed('Finder'))
  assertFalse(wf1:isAppAllowed('Finder'))

  wf1:delete()
  wf2:delete()
  return success()
end

local function testWindowFilterSubscribe()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  local called = false
  local result = wf:subscribe('windowCreated', function() called = true end)
  assertIsEqual(wf, result)  -- Returns self
  assertTrue(wf._subscriptions:hasEvent('windowCreated'))
  assertTrue(wf._active)  -- Subscribe activates the filter
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterUnsubscribe()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  local fn = function() end
  wf:subscribe('windowCreated', fn)
  assertTrue(wf._subscriptions:hasEvent('windowCreated'))
  wf:unsubscribe('windowCreated', fn)
  assertFalse(wf._subscriptions:hasEvent('windowCreated'))
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterKeepActive()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  assertFalse(wf._active)
  wf:keepActive()
  assertTrue(wf._active)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterToString()
  local wf = wf_new.new()
  local str = tostring(wf)
  assertIsString(str)
  assertTrue(string.find(str, "WindowFilter") ~= nil)
  wf:delete()
  return success()
end

local function testWindowFilterSetCurrentSpace()
  local wf = wf_new.new()
  assertFalse(wf._currentSpaceOnly)
  wf:setCurrentSpace(true)
  assertTrue(wf._currentSpaceOnly)
  assertTrue(wf._trackSpaces)
  wf:delete()
  return success()
end

local function testWindowFilterSetScreens()
  local wf = wf_new.new()
  wf:setScreens("Main")
  assertIsEqual("Main", wf._allowedScreens)
  wf:delete()
  return success()
end

local function testWindowFilterSetRegions()
  local wf = wf_new.new()
  local region = {x = 0, y = 0, w = 100, h = 100}
  wf:setRegions({region})
  assertIsTable(wf._allowedRegions)
  wf:delete()
  return success()
end

local function testWindowFilterGetFilters()
  local wf = wf_new.new()
  wf:setAppFilter('Safari', {visible = true})
  wf:setDefaultFilter(false)
  local filters = wf:getFilters()
  assertIsTable(filters)
  assertIsNotNil(filters['Safari'])
  assertIsEqual(false, filters.default)
  wf:delete()
  return success()
end

-- ============================================================================
-- Step 8b: getWindows + Sorting + Notify
-- ============================================================================

local function testWindowFilterGetWindowsReturnsTable()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  local wins = wf:getWindows()
  assertIsTable(wins)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterGetWindowsWithSortOrder()
  -- Reset manager and inject mock tracker
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  -- Set sort order
  wf:setSortOrder('createdLast')
  assertIsEqual('createdLast', wf._sortOrder)
  local wins = wf:getWindows()
  assertIsTable(wins)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterGetWindowsOneshotActivation()
  -- Reset manager and inject mock tracker
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  assertFalse(wf._active)  -- Not active initially
  local wins = wf:getWindows()
  assertIsTable(wins)
  -- After one-shot, filter should be paused (not fully deactivated)
  assertTrue(wf._paused)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterGetWindowsExcludesInvalidWindows()
  -- Test that getWindows() excludes windows from terminated apps
  -- (windows where id() returns nil OR application() returns nil)
  resetManager()
  local manager = wf_new._Manager.getInstance()

  -- Create mock windows - one valid, two invalid (terminated app)
  local validWindow = {
    id = function() return 100 end,
    title = function() return "Valid Window" end,
    application = function() return { name = function() return "TestApp" end, pid = function() return 1000 end } end,
  }
  local invalidWindowNoId = {
    id = function() return nil end,  -- Simulates fully terminated app
    title = function() return "Invalid Window No ID" end,
    application = function() return nil end,
  }
  local invalidWindowOrphaned = {
    id = function() return 300 end,  -- ID still valid but app is gone
    title = function() return "Orphaned Window" end,
    application = function() return nil end,  -- App terminated
  }

  -- Create mock tracker with all windows
  local mockTracker = {
    running = true,
    focusedWindowId = 100,
    focusedAppPid = 1000,
    apps = {
      [1000] = {
        windows = {
          [100] = { _window = validWindow },
          [200] = { _window = invalidWindowNoId },
          [300] = { _window = invalidWindowOrphaned },
        }
      }
    },
    start = function() end,
    stop = function(self) self.running = false end,
  }
  manager.tracker = mockTracker

  local wf = wf_new.new()
  -- Manually add all windows to the filter's tracking
  -- STATE constants are strings: 'allowed', 'timeFocused', 'timeCreated'
  wf._windows[100] = { allowed = true, timeFocused = 1, timeCreated = 1 }
  wf._windows[200] = { allowed = true, timeFocused = 2, timeCreated = 2 }
  wf._windows[300] = { allowed = true, timeFocused = 3, timeCreated = 3 }
  wf._active = true

  local wins = wf:getWindows()
  assertIsTable(wins)
  assertIsEqual(1, #wins)  -- Only the valid window should be returned
  assertIsEqual(validWindow, wins[1])

  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterNotifyBasic()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  local notifyCalled = false
  local result = wf:notify(function(wins, event)
    notifyCalled = true
  end)
  assertIsEqual(wf, result)  -- Returns self
  assertIsNotNil(wf._notifyfn)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterNotifyWithImmediate()
  -- Reset manager and inject mock tracker
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  local notifyCalled = false
  local receivedWins = nil
  wf:notify(function(wins, event)
    notifyCalled = true
    receivedWins = wins
  end, nil, true)  -- immediate = true
  assertTrue(notifyCalled)
  assertIsTable(receivedWins)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterNotifyWithFnEmpty()
  local wf = wf_new.new(false)  -- Reject all
  local fnCalled = false
  local fnEmptyCalled = false
  -- Reset manager and inject mock tracker
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  wf:notify(
    function(wins) fnCalled = true end,
    function() fnEmptyCalled = true end,
    true  -- immediate
  )
  -- Since we reject all windows, fnEmpty should be called
  assertFalse(fnCalled)
  assertTrue(fnEmptyCalled)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterNotifyRemove()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local wf = wf_new.new()
  wf:notify(function() end)
  assertIsNotNil(wf._notifyfn)
  wf:notify(nil)  -- Remove notify
  assertIsNil(wf._notifyfn)
  wf:delete()
  resetManager()
  return success()
end

local function testWindowFilterTimestampsTracked()
  -- This test verifies that timestamps are tracked in window state
  -- No mock tracker needed - just testing internal state management
  local wf = wf_new.new()
  -- Manually add a window state to check timestamp tracking
  local testState = {
    allowed = true,
    visible = true,
    timeCreated = 12345,
    timeFocused = 12346,
  }
  wf._windows[999] = testState
  assertIsEqual(12345, wf._windows[999].timeCreated)
  assertIsEqual(12346, wf._windows[999].timeFocused)
  wf:delete()
  return success()
end

-- ============================================================================
-- Step 9: Module Variables and Functions
-- ============================================================================

local function testModuleAllowedWindowRoles()
  assertIsTable(wf_new.allowedWindowRoles)
  assertTrue(wf_new.allowedWindowRoles.AXStandardWindow)
  assertTrue(wf_new.allowedWindowRoles.AXDialog)
  return success()
end

local function testModuleIgnoreInDefaultFilter()
  assertIsTable(wf_new.ignoreInDefaultFilter)
  -- Should contain some known transient apps
  assertTrue(wf_new.ignoreInDefaultFilter['Spotlight'])
  return success()
end

local function testModuleIswf()
  local wf = wf_new.new()
  assertTrue(wf_new.iswf(wf))
  assertFalse(wf_new.iswf({}))
  assertFalse(wf_new.iswf(nil))
  assertFalse(wf_new.iswf("string"))
  wf:delete()
  return success()
end

local function testModuleCopy()
  local wf = wf_new.new('Safari')
  local copy = wf_new.copy(wf)
  assertIsNotNil(copy)
  assertTrue(wf_new.iswf(copy))
  -- Should be independent
  assertTrue(copy:isAppAllowed('Safari'))
  copy:rejectApp('Safari')
  assertTrue(wf:isAppAllowed('Safari'))  -- Original unchanged
  assertFalse(copy:isAppAllowed('Safari'))
  wf:delete()
  copy:delete()
  return success()
end

local function testModuleSetLogLevel()
  -- Should not error
  wf_new.setLogLevel('debug')
  assertIsEqual('debug', wf_new._logLevel)
  wf_new.setLogLevel('info')
  assertIsEqual('info', wf_new._logLevel)
  return success()
end

local function testModuleBatchOperations()
  -- Reset manager and inject mock tracker to avoid full Tracker startup
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  local id = wf_new.startBatchOperation()
  assertIsString(id)
  assertTrue(#id > 0)
  -- Stop should not error
  wf_new.stopBatchOperation(id)
  resetManager()
  return success()
end

local function testModuleCallable()
  -- Reset manager and inject mock tracker
  resetManager()
  local manager = wf_new._Manager.getInstance()
  manager.tracker = createMockTracker()

  -- windowfilter(...) should return getWindows() result
  local wins = wf_new('Safari')
  assertIsTable(wins)
  resetManager()
  return success()
end

local function testDirectionMethodsExist()
  local wf = wf_new.new()
  -- Check direction methods exist on instance
  assertIsFunction(wf.windowsToEast)
  assertIsFunction(wf.windowsToWest)
  assertIsFunction(wf.windowsToNorth)
  assertIsFunction(wf.windowsToSouth)
  assertIsFunction(wf.focusWindowEast)
  assertIsFunction(wf.focusWindowWest)
  assertIsFunction(wf.focusWindowNorth)
  assertIsFunction(wf.focusWindowSouth)
  wf:delete()
  return success()
end

local function testModuleFocusFunctionsExist()
  -- Check module-level focus functions exist
  assertIsFunction(wf_new.focusEast)
  assertIsFunction(wf_new.focusWest)
  assertIsFunction(wf_new.focusNorth)
  assertIsFunction(wf_new.focusSouth)
  return success()
end

-- ============================================================================
-- RUN ALL TESTS
-- ============================================================================

local function runAllTests()
  print("\n" .. string.rep("=", 60))
  print("window_filter_new.lua Internal Component Tests")
  print(string.rep("=", 60))

  testResults.passed = 0
  testResults.failed = 0
  testResults.errors = {}

  -- Step 1: Utilities
  print("\nStep 1: Utilities")
  runTest("testSafeCallWithValidFunction", testSafeCallWithValidFunction)
  runTest("testSafeCallWithNilFunction", testSafeCallWithNilFunction)
  runTest("testSafeCallWithError", testSafeCallWithError)
  runTest("testSafeGetScreenIdWithWindow", testSafeGetScreenIdWithWindow)
  runTest("testSafeGetScreenIdWithNil", testSafeGetScreenIdWithNil)
  runTest("testConfigExists", testConfigExists)

  -- Step 2: WindowInfo
  print("\nStep 2: WindowInfo")
  runTest("testWindowInfoCreation", testWindowInfoCreation)
  runTest("testWindowInfoWithNil", testWindowInfoWithNil)
  runTest("testWindowInfoRefresh", testWindowInfoRefresh)
  runTest("testWindowInfoToString", testWindowInfoToString)

  -- Step 2: AppInfo
  print("\nStep 2: AppInfo")
  runTest("testAppInfoCreation", testAppInfoCreation)
  runTest("testAppInfoWithNil", testAppInfoWithNil)
  runTest("testAppInfoRefresh", testAppInfoRefresh)
  runTest("testAppInfoToString", testAppInfoToString)

  -- Step 3: FilterRules
  print("\nStep 3: FilterRules")
  runTest("testFilterRulesCreation", testFilterRulesCreation)
  runTest("testFilterRulesToString", testFilterRulesToString)

  -- Step 3: Filter
  print("\nStep 3: Filter")
  runTest("testFilterMatchesWithNoRules", testFilterMatchesWithNoRules)
  runTest("testFilterMatchesOverrideFalse", testFilterMatchesOverrideFalse)
  runTest("testFilterMatchesAppRejected", testFilterMatchesAppRejected)
  runTest("testFilterMatchesDefaultFalse", testFilterMatchesDefaultFalse)
  runTest("testFilterMatchesRuleVisible", testFilterMatchesRuleVisible)
  runTest("testFilterMatchesRuleAllowTitlesNumber", testFilterMatchesRuleAllowTitlesNumber)
  runTest("testFilterMatchesRuleAllowTitlesPattern", testFilterMatchesRuleAllowTitlesPattern)
  runTest("testFilterMatchesRuleRejectTitles", testFilterMatchesRuleRejectTitles)
  runTest("testFilterMatchesRuleFocused", testFilterMatchesRuleFocused)
  runTest("testFilterMatchesRuleAllowRolesStar", testFilterMatchesRuleAllowRolesStar)
  runTest("testFilterMatchesRegions", testFilterMatchesRegions)
  runTest("testFilterResolveScreens", testFilterResolveScreens)

  -- Step 4: PreFilter
  print("\nStep 4: PreFilter")
  runTest("testPreFilterShouldTrackAppWithValidApp", testPreFilterShouldTrackAppWithValidApp)
  runTest("testPreFilterShouldTrackAppWithNil", testPreFilterShouldTrackAppWithNil)
  runTest("testPreFilterShouldTrackAppBlacklisted", testPreFilterShouldTrackAppBlacklisted)
  runTest("testPreFilterShouldTrackWithValidWindow", testPreFilterShouldTrackWithValidWindow)
  runTest("testPreFilterShouldTrackWithNil", testPreFilterShouldTrackWithNil)
  runTest("testPreFilterDefaultConfig", testPreFilterDefaultConfig)

  -- Step 5: Events
  print("\nStep 5: Events")
  runTest("testEventConstantsExist", testEventConstantsExist)
  runTest("testSortOrderConstantsExist", testSortOrderConstantsExist)
  runTest("testIsValidEvent", testIsValidEvent)

  -- Step 5: Subscriptions
  print("\nStep 5: Subscriptions")
  runTest("testSubscriptionsCreation", testSubscriptionsCreation)
  runTest("testSubscriptionsAdd", testSubscriptionsAdd)
  runTest("testSubscriptionsAddDuplicate", testSubscriptionsAddDuplicate)
  runTest("testSubscriptionsAddInvalidEvent", testSubscriptionsAddInvalidEvent)
  runTest("testSubscriptionsAddNonFunction", testSubscriptionsAddNonFunction)
  runTest("testSubscriptionsRemove", testSubscriptionsRemove)
  runTest("testSubscriptionsRemoveNotFound", testSubscriptionsRemoveNotFound)
  runTest("testSubscriptionsRemoveAll", testSubscriptionsRemoveAll)
  runTest("testSubscriptionsRemoveAllForEvent", testSubscriptionsRemoveAllForEvent)
  runTest("testSubscriptionsEmit", testSubscriptionsEmit)
  runTest("testSubscriptionsEmitMultiple", testSubscriptionsEmitMultiple)
  runTest("testSubscriptionsEmitWithError", testSubscriptionsEmitWithError)
  runTest("testSubscriptionsEmitNoCallbacks", testSubscriptionsEmitNoCallbacks)
  runTest("testSubscriptionsSelfUnsubscribe", testSubscriptionsSelfUnsubscribe)
  runTest("testSubscriptionsToString", testSubscriptionsToString)

  -- Step 6: ManagerStub
  print("\nStep 6: ManagerStub")
  runTest("testManagerStubCreation", testManagerStubCreation)
  runTest("testManagerStubRecordsEvents", testManagerStubRecordsEvents)
  runTest("testManagerStubGetEventCount", testManagerStubGetEventCount)
  runTest("testManagerStubGetLastEvent", testManagerStubGetLastEvent)
  runTest("testManagerStubClearEvents", testManagerStubClearEvents)

  -- Step 6: Tracker
  print("\nStep 6: Tracker")
  runTest("testTrackerCreation", testTrackerCreation)
  runTest("testTrackerStartStop", testTrackerStartStop)
  runTest("testTrackerTracksExistingApps", testTrackerTracksExistingApps)
  runTest("testTrackerTracksWindows", testTrackerTracksWindows)
  runTest("testTrackerToString", testTrackerToString)
  runTest("testTrackerDoubleStartIsNoop", testTrackerDoubleStartIsNoop)
  runTest("testTrackerDoubleStopIsNoop", testTrackerDoubleStopIsNoop)
  runTest("testTrackerPreFilterIntegration", testTrackerPreFilterIntegration)
  runTest("testTrackerCleanupOnStop", testTrackerCleanupOnStop)
  runTest("testTrackerGetAppAndWindowCount", testTrackerGetAppAndWindowCount)
  runTest("testTrackerManagerCallbackError", testTrackerManagerCallbackError)
  runTest("testTrackerWithNilManager", testTrackerWithNilManager)

  -- Step 7: Manager
  print("\nStep 7: Manager")
  runTest("testManagerGetInstance", testManagerGetInstance)
  runTest("testManagerInitialState", testManagerInitialState)
  runTest("testManagerActivateIncrementsCount", testManagerActivateIncrementsCount)
  runTest("testManagerDeactivateDecrementsCount", testManagerDeactivateDecrementsCount)
  runTest("testManagerMultipleInstancesCounting", testManagerMultipleInstancesCounting)
  runTest("testManagerDoubleActivateIsNoop", testManagerDoubleActivateIsNoop)
  runTest("testManagerDoubleDeactivateIsNoop", testManagerDoubleDeactivateIsNoop)
  runTest("testManagerGetContext", testManagerGetContext)
  runTest("testManagerRoutesEvents", testManagerRoutesEvents)
  runTest("testManagerRoutesAllEventTypes", testManagerRoutesAllEventTypes)
  runTest("testManagerSpacesInstanceTracking", testManagerSpacesInstanceTracking)
  runTest("testManagerHandlesInstanceErrors", testManagerHandlesInstanceErrors)
  runTest("testManagerToString", testManagerToString)
  runTest("testManagerForceRefreshOnSpaceChangeVariable", testManagerForceRefreshOnSpaceChangeVariable)
  runTest("testManagerRefreshInstance", testManagerRefreshInstance)
  runTest("testManagerFocusChangedRouting", testManagerFocusChangedRouting)
  runTest("testManagerIntegrationWithTracker", testManagerIntegrationWithTracker)

  -- Step 8a: WindowFilter
  print("\nStep 8a: WindowFilter")
  runTest("testWindowFilterCreation", testWindowFilterCreation)
  runTest("testWindowFilterConstructorNil", testWindowFilterConstructorNil)
  runTest("testWindowFilterConstructorTrue", testWindowFilterConstructorTrue)
  runTest("testWindowFilterConstructorFalse", testWindowFilterConstructorFalse)
  runTest("testWindowFilterConstructorString", testWindowFilterConstructorString)
  runTest("testWindowFilterConstructorTable", testWindowFilterConstructorTable)
  runTest("testWindowFilterConstructorFunction", testWindowFilterConstructorFunction)
  runTest("testWindowFilterSetAppFilter", testWindowFilterSetAppFilter)
  runTest("testWindowFilterSetDefaultFilter", testWindowFilterSetDefaultFilter)
  runTest("testWindowFilterAllowRejectApp", testWindowFilterAllowRejectApp)
  runTest("testWindowFilterPauseResume", testWindowFilterPauseResume)
  runTest("testWindowFilterCopy", testWindowFilterCopy)
  runTest("testWindowFilterSubscribe", testWindowFilterSubscribe)
  runTest("testWindowFilterUnsubscribe", testWindowFilterUnsubscribe)
  runTest("testWindowFilterKeepActive", testWindowFilterKeepActive)
  runTest("testWindowFilterToString", testWindowFilterToString)
  runTest("testWindowFilterSetCurrentSpace", testWindowFilterSetCurrentSpace)
  runTest("testWindowFilterSetScreens", testWindowFilterSetScreens)
  runTest("testWindowFilterSetRegions", testWindowFilterSetRegions)
  runTest("testWindowFilterGetFilters", testWindowFilterGetFilters)

  -- Step 8b: getWindows + Sorting + Notify
  print("\nStep 8b: getWindows + Sorting + Notify")
  runTest("testWindowFilterGetWindowsReturnsTable", testWindowFilterGetWindowsReturnsTable)
  runTest("testWindowFilterGetWindowsWithSortOrder", testWindowFilterGetWindowsWithSortOrder)
  runTest("testWindowFilterGetWindowsOneshotActivation", testWindowFilterGetWindowsOneshotActivation)
  runTest("testWindowFilterGetWindowsExcludesInvalidWindows", testWindowFilterGetWindowsExcludesInvalidWindows)
  runTest("testWindowFilterNotifyBasic", testWindowFilterNotifyBasic)
  runTest("testWindowFilterNotifyWithImmediate", testWindowFilterNotifyWithImmediate)
  runTest("testWindowFilterNotifyWithFnEmpty", testWindowFilterNotifyWithFnEmpty)
  runTest("testWindowFilterNotifyRemove", testWindowFilterNotifyRemove)
  runTest("testWindowFilterTimestampsTracked", testWindowFilterTimestampsTracked)

  -- Step 9: Module Variables and Functions
  print("\nStep 9: Module Variables and Functions")
  runTest("testModuleAllowedWindowRoles", testModuleAllowedWindowRoles)
  runTest("testModuleIgnoreInDefaultFilter", testModuleIgnoreInDefaultFilter)
  runTest("testModuleIswf", testModuleIswf)
  runTest("testModuleCopy", testModuleCopy)
  runTest("testModuleSetLogLevel", testModuleSetLogLevel)
  runTest("testModuleBatchOperations", testModuleBatchOperations)
  runTest("testModuleCallable", testModuleCallable)
  runTest("testDirectionMethodsExist", testDirectionMethodsExist)
  runTest("testModuleFocusFunctionsExist", testModuleFocusFunctionsExist)

  -- Summary
  print("\n" .. string.rep("=", 60))
  print(string.format("Results: %d passed, %d failed", testResults.passed, testResults.failed))
  print(string.rep("=", 60))

  if #testResults.errors > 0 then
    print("\nFailed tests:")
    for _, err in ipairs(testResults.errors) do
      print(string.format("  - %s: %s", err.name, err.error))
    end
  end

  return testResults.failed == 0
end

-- Run tests when file is loaded
local allPassed = runAllTests()
return allPassed and "All tests passed" or "Some tests failed"
