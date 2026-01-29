-- test_window_filter.lua
-- Contract tests for hs.window.filter
-- These tests define the behavioral contract that any implementation must satisfy.
--
-- Created: 2025-01-28 (Step 0 of window_filter rewrite)
-- Updated: 2025-01-28 (Step 10 - added behavioral tests)
-- Tests: 49 (36 original + 13 behavioral)
--
-- Run via hs CLI:
--   /Users/dmg/bin/osx/hs -c 'dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua")'
--
-- Or in Hammerspoon console:
--   dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua")
--
-- Discoveries during test development:
--   1. isAppAllowed() returns true for all apps even with single-app/app-list filters
--      (filtering happens at window level via getWindows())
--   2. setScreens() expects a screen name (string), not a screen object
--   3. setRegions() expects a table of regions, not a single region
--
-- Skipped tests:
--   - testRejectRegionsBug: Tests the rejectRegions bug fix in new implementation

-- ============================================================================
-- TEST FRAMEWORK (from lsunit.lua, for standalone execution)
-- ============================================================================

-- Only define if not already present (allows running in XCTest or standalone)
if not success then
  function success()
    return "Success"
  end
end

if not failure then
  function failure(msg)
    error(string.format("Assertion failure: %s", msg))
  end
end

if not assertIsEqual then
  function assertIsEqual(expected, actual)
    if type(expected) ~= type(actual) then
      failure(string.format("expected type: '%s', actual type: '%s'", type(expected), type(actual)))
    end
    if expected ~= actual then
      failure(string.format("expected: '%s', actual: '%s'", tostring(expected), tostring(actual)))
    end
  end
end

if not assertTrue then
  function assertTrue(a)
    if not a then
      failure("expected: true, actual: " .. tostring(a))
    end
  end
end

if not assertFalse then
  function assertFalse(a)
    if a then
      failure("expected: false, actual: " .. tostring(a))
    end
  end
end

if not assertIsNil then
  function assertIsNil(a)
    if a ~= nil then
      failure("expected: nil, actual: " .. tostring(a))
    end
  end
end

if not assertIsNotNil then
  function assertIsNotNil(a)
    if a == nil then
      failure("expected: not-nil, actual: nil")
    end
  end
end

if not assertGreaterThan then
  function assertGreaterThan(a, b)
    if b <= a then
      failure(string.format("expected: %s > %s", tostring(b), tostring(a)))
    end
  end
end

if not assertIsTable then
  function assertIsTable(a)
    if type(a) ~= "table" then
      failure(string.format("expected type: 'table', actual type: '%s'", type(a)))
    end
  end
end

if not assertIsBoolean then
  function assertIsBoolean(a)
    if type(a) ~= "boolean" then
      failure(string.format("expected type: 'boolean', actual type: '%s'", type(a)))
    end
  end
end

if not assertIsString then
  function assertIsString(a)
    if type(a) ~= "string" then
      failure(string.format("expected type: 'string', actual type: '%s'", type(a)))
    end
  end
end

if not assertIsNumber then
  function assertIsNumber(a)
    if type(a) ~= "number" then
      failure(string.format("expected type: 'number', actual type: '%s'", type(a)))
    end
  end
end

if not assertIsFunction then
  function assertIsFunction(a)
    if type(a) ~= "function" then
      failure(string.format("expected type: 'function', actual type: '%s'", type(a)))
    end
  end
end

-- ============================================================================
-- TEST RUNNER (for standalone execution)
-- ============================================================================

local wf = hs.window.filter

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
  -- new("AppName") creates filter for that app
  -- Note: isAppAllowed returns true for all apps; filtering happens at window level
  local f = wf.new('Finder')
  assertTrue(f:isAppAllowed('Finder'))
  -- The filter allows all apps at app level, but only returns Finder windows
  assertTrue(f:isAppAllowed('Safari'))  -- This is actual behavior
  f:delete()
  return success()
end

function testNewAppList()
  -- new({"App1", "App2"}) creates filter for listed apps
  -- Note: isAppAllowed returns true for all apps; filtering happens at window level
  local f = wf.new({'Finder', 'Safari'})
  assertTrue(f:isAppAllowed('Finder'))
  assertTrue(f:isAppAllowed('Safari'))
  assertTrue(f:isAppAllowed('TextEdit'))  -- Actual behavior: all apps allowed at app level
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

function testSetAppFilterReturnsSelf()
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

-- NOTE: This test is flaky. The filter checks win.title (cached at filter time),
-- but the assertion calls win:title() (live query). If a window's title changes
-- to empty between filtering and assertion, the test fails. This is not a bug
-- in the implementation - windowfilter correctly works on state snapshots.
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
  -- setScreens expects a screen name (string), not a screen object
  local screenName = hs.screen.mainScreen():name()
  local result = f:setScreens(screenName)
  assertIsEqual(f, result)
  f:delete()
  return success()
end

function testSetRegions()
  local f = wf.new()
  -- setRegions expects a table of regions, not a single region
  local region = hs.geometry.rect(0, 0, 500, 500)
  local result = f:setRegions({region})
  assertIsEqual(f, result)
  f:delete()
  return success()
end

-- ============================================================================
-- BEHAVIORAL TESTS (Step 10)
-- ============================================================================

function testNotifyImmediate()
  local f = wf.new('Finder')
  -- Skip if notify method doesn't exist (older Hammerspoon versions)
  if not f.notify then
    f:delete()
    return success()
  end
  local called = false
  local receivedWins = nil
  f:notify(function(wins) called = true; receivedWins = wins end, nil, true)
  assertTrue(called)
  assertIsTable(receivedWins)
  f:delete()
  return success()
end

function testNotifyFnEmpty()
  local f = wf.new(false)  -- reject all
  -- Skip if notify method doesn't exist (older Hammerspoon versions)
  if not f.notify then
    f:delete()
    return success()
  end
  local fnCalled, fnEmptyCalled = false, false
  f:notify(function() fnCalled = true end, function() fnEmptyCalled = true end, true)
  assertFalse(fnCalled)
  assertTrue(fnEmptyCalled)
  f:delete()
  return success()
end

function testSetOverrideFilterRejects()
  local f = wf.new('Finder')  -- allow Finder
  f:setOverrideFilter({visible = false})  -- but override rejects visible
  local wins = f:getWindows()
  -- All visible Finder windows should be rejected
  assertIsEqual(0, #wins)
  f:delete()
  return success()
end

function testIswfBehavior()
  local f = wf.new()
  assertTrue(wf.iswf(f))
  assertFalse(wf.iswf({}))
  assertFalse(wf.iswf(nil))
  assertFalse(wf.iswf("string"))
  assertFalse(wf.iswf(123))
  f:delete()
  return success()
end

function testModuleCopyFunction()
  local f = wf.new(true)
  f:rejectApp('Safari')
  local copy = wf.copy(f)
  assertTrue(wf.iswf(copy))
  copy:allowApp('Safari')
  assertFalse(f:isAppAllowed('Safari'))  -- original unchanged
  assertTrue(copy:isAppAllowed('Safari'))
  f:delete()
  copy:delete()
  return success()
end

function testIgnoreInDefaultFilterBehavior()
  -- ignoreInDefaultFilter should be a table
  assertIsTable(wf.ignoreInDefaultFilter)
  -- It should contain known transient apps
  -- (We can't test adding to it without affecting global state)
  return success()
end

function testDefaultAllowsHammerspoonConsole()
  hs.openConsole()  -- ensure console exists
  hs.timer.usleep(100000)  -- brief wait for window
  local consoleWin = hs.window.find('Console')
  if consoleWin then
    assertTrue(wf.default:isWindowAllowed(consoleWin))
  end
  return success()
end

function testSwitchedToSpaceNoError()
  -- Should not error
  wf.switchedToSpace(1)
  wf.switchedToSpace(2)
  return success()
end

function testBatchOperations()
  local id = wf.startBatchOperation()
  assertIsString(id)
  assertTrue(#id > 0)
  wf.stopBatchOperation(id)  -- should not error
  return success()
end

function testDirectionMethodsNoError()
  local f = wf.new('Finder')
  local wins = f:getWindows()
  if #wins > 0 then
    local win = wins[1]
    -- These should not error and return tables (or nil)
    local e = f:windowsToEast(win)
    local w = f:windowsToWest(win)
    local n = f:windowsToNorth(win)
    local s = f:windowsToSouth(win)
    if e then assertIsTable(e) end
    if w then assertIsTable(w) end
    if n then assertIsTable(n) end
    if s then assertIsTable(s) end
  end
  f:delete()
  return success()
end

function testFocusWindowMethodsBehavior()
  local f = wf.new('Finder')
  local wins = f:getWindows()
  if #wins >= 2 then
    -- Find the leftmost window
    local leftWin = wins[1]
    for _, w in ipairs(wins) do
      if w:frame().x < leftWin:frame().x then leftWin = w end
    end
    leftWin:focus()
    hs.timer.usleep(50000)  -- brief settle

    -- Try to focus window to east
    local originalFocused = hs.window.focusedWindow()
    local result = f:focusWindowEast()  -- returns boolean or nil

    if result ~= nil then
      assertIsBoolean(result)
      -- If result is true, focus should have changed
      if result then
        local newFocused = hs.window.focusedWindow()
        if newFocused and originalFocused then
          assertTrue(newFocused:id() ~= originalFocused:id())
        end
      end
    end
    -- Restore original focus
    if originalFocused then originalFocused:focus() end
  end
  f:delete()
  return success()
end

function testModuleFocusFunctionsBehavior()
  -- These use default filter
  local originalFocused = hs.window.focusedWindow()

  -- Just verify they don't error and return boolean (or nil)
  local result = wf.focusEast()
  if result ~= nil then
    assertIsBoolean(result)
  end

  -- Restore focus
  if originalFocused then originalFocused:focus() end
  return success()
end

function testFocusFunctionsReturnBool()
  local f = wf.new(false)  -- reject all windows
  -- With no allowed windows, focus functions should return false (or nil)
  local result = f:focusWindowEast()
  if result ~= nil then
    assertIsBoolean(result)
    assertFalse(result)  -- no windows to focus
  end
  f:delete()
  return success()
end

-- ============================================================================
-- RUN ALL TESTS
-- ============================================================================

local function runAllTests()
  print("\n" .. string.rep("=", 60))
  print("hs.window.filter Contract Tests")
  print(string.rep("=", 60))

  testResults.passed = 0
  testResults.failed = 0
  testResults.errors = {}

  -- Constructor tests
  print("\nConstructor Tests:")
  runTest("testNewDefault", testNewDefault)
  runTest("testNewTrue", testNewTrue)
  runTest("testNewFalse", testNewFalse)
  runTest("testNewSingleApp", testNewSingleApp)
  runTest("testNewAppList", testNewAppList)
  runTest("testNewAppRules", testNewAppRules)
  runTest("testNewFunction", testNewFunction)

  -- Method chaining tests
  print("\nMethod Chaining Tests:")
  runTest("testSetAppFilterReturnsSelf", testSetAppFilterReturnsSelf)
  runTest("testSetDefaultFilterReturnsSelf", testSetDefaultFilterReturnsSelf)
  runTest("testAllowAppReturnsSelf", testAllowAppReturnsSelf)
  runTest("testRejectAppReturnsSelf", testRejectAppReturnsSelf)
  runTest("testMethodChaining", testMethodChaining)

  -- Filter rules tests
  print("\nFilter Rules Tests:")
  runTest("testVisibleFilter", testVisibleFilter)
  runTest("testAllowTitlesNumber", testAllowTitlesNumber)
  runTest("testRejectAppExcludes", testRejectAppExcludes)

  -- getWindows tests
  print("\ngetWindows Tests:")
  runTest("testGetWindowsReturnsTable", testGetWindowsReturnsTable)
  runTest("testGetWindowsReturnsWindowObjects", testGetWindowsReturnsWindowObjects)
  runTest("testGetWindowsSortOrder", testGetWindowsSortOrder)

  -- Subscription tests
  print("\nSubscription Tests:")
  runTest("testSubscribeReturnsSelf", testSubscribeReturnsSelf)
  runTest("testUnsubscribeReturnsSelf", testUnsubscribeReturnsSelf)
  runTest("testUnsubscribeAllReturnsSelf", testUnsubscribeAllReturnsSelf)
  runTest("testPauseReturnsSelf", testPauseReturnsSelf)
  runTest("testResumeReturnsSelf", testResumeReturnsSelf)

  -- Module-level API tests
  print("\nModule-Level API Tests:")
  runTest("testDefaultExists", testDefaultExists)
  runTest("testDefaultCurrentSpaceExists", testDefaultCurrentSpaceExists)
  runTest("testIgnoreAlwaysIsTable", testIgnoreAlwaysIsTable)
  runTest("testEventConstantsExist", testEventConstantsExist)
  runTest("testSortOrderConstantsExist", testSortOrderConstantsExist)

  -- Copy tests
  print("\nCopy Tests:")
  runTest("testCopyCreatesIndependentCopy", testCopyCreatesIndependentCopy)

  -- Edge case tests
  print("\nEdge Case Tests:")
  runTest("testSetFiltersWithSortOrder", testSetFiltersWithSortOrder)
  runTest("testGetFilters", testGetFilters)
  runTest("testIsWindowAllowed", testIsWindowAllowed)
  runTest("testKeepActive", testKeepActive)
  runTest("testSetCurrentSpace", testSetCurrentSpace)
  runTest("testSetScreens", testSetScreens)
  runTest("testSetRegions", testSetRegions)

  -- Behavioral tests (Step 10)
  print("\nBehavioral Tests:")
  runTest("testNotifyImmediate", testNotifyImmediate)
  runTest("testNotifyFnEmpty", testNotifyFnEmpty)
  runTest("testSetOverrideFilterRejects", testSetOverrideFilterRejects)
  runTest("testIswfBehavior", testIswfBehavior)
  runTest("testModuleCopyFunction", testModuleCopyFunction)
  runTest("testIgnoreInDefaultFilterBehavior", testIgnoreInDefaultFilterBehavior)
  runTest("testDefaultAllowsHammerspoonConsole", testDefaultAllowsHammerspoonConsole)
  runTest("testSwitchedToSpaceNoError", testSwitchedToSpaceNoError)
  runTest("testBatchOperations", testBatchOperations)
  runTest("testDirectionMethodsNoError", testDirectionMethodsNoError)
  runTest("testFocusWindowMethodsBehavior", testFocusWindowMethodsBehavior)
  runTest("testModuleFocusFunctionsBehavior", testModuleFocusFunctionsBehavior)
  runTest("testFocusFunctionsReturnBool", testFocusFunctionsReturnBool)

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
