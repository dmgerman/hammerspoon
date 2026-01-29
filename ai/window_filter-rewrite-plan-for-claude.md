# hs.window.filter Implementation Guidance for Claude

**Related Documents:**
- [Main Plan](window_filter-rewrite-plan.md) - Goals, architecture, phases
- [Technical Reference](window_filter-rewrite-info.md) - Data structures, specs, API matrix

---

This section provides explicit guidance for Claude (the AI assistant) on how to implement this rewrite. The implementation should be **incremental and test-driven**, not a single monolithic step.

## Development Pragmatics (Early Stages)

For Steps 1-4, use the simplest approach:
- **Dependencies**: Use global `hs.*` namespace directly (e.g., `hs.application`, `hs.timer`) - no `require()` for `dofile()` compatibility
- **Logging**: Use `print()` for development visibility via `hs` CLI (switch to proper logger later)
- **Internal testing**: Test utilities manually via `hs` CLI (they're not public API)
- **Constants**: Use plan values initially; tune later based on real-world testing
- **NEVER COMMIT**: Claude must never run `git commit`. Only the user commits. Provide commit messages when asked.

This keeps early development fast. Formalize later if needed.

## Development Conventions (Established)

These conventions were decided during implementation and should be followed consistently:

1. **Avoid global state**: Always prefer passing state explicitly (via parameters or object properties) over using module-level globals. Global state makes code harder to reason about, test, and maintain. Only use globals when strictly necessary (e.g., singleton Manager instance).

2. **Code style**: Follow `window.lua` conventions
   - Local caching of globals at top of file
   - Minimal whitespace
   - Line length ~100 chars max
   - LuaDoc comments for functions

3. **File structure**: All components in single file `window_filter_new.lua` (not split into modules)

4. **Testing exposure**: Expose internal components with `_` prefix for development testing
   - Examples: `_WindowInfo`, `_AppInfo`, `_safeCall`, `_config`
   - Contract tests (Step 10) validate through public API only

5. **Test execution**: Run tests via `hs` CLI on demand with user approval
   ```bash
   /Users/dmg/bin/osx/hs -c 'local wf = dofile("..."); ...'
   ```

6. **Module header**: Full LuaDoc module header from the start (not deferred)

7. **Documentation discipline**: After completing each step:
   - Update CLAUDE.md status
   - Add completion marker to step in this plan
   - Document any new design decisions in relevant step section

8. **Mandatory testing for each step**: Every step MUST include persistent tests:
   - **Contract tests**: `test_window_filter.lua` - Public API tests (work with old and new implementations)
   - **Internal tests**: `test_window_filter_internals.lua` - Component tests via `_` prefixed exports
   - Tests load `window_filter_new.lua` via dofile
   - Tests verify component behavior and catch regressions
   - **ALWAYS run BOTH test files before marking step complete** - no exceptions
   - Run both test files to ensure no regressions:
     ```bash
     /Users/dmg/bin/osx/hs -c 'dofile(".../test_window_filter.lua")'
     /Users/dmg/bin/osx/hs -c 'dofile(".../test_window_filter_internals.lua")'
     ```
   - Both must pass before step is considered complete

---

## Core Principles

1. **Never write a component without tests first** - Write the test, see it fail, implement the component, see it pass
2. **Small, verifiable steps** - Each step should be completable and testable in a single session
3. **API compatibility verification at each step** - Don't proceed if existing API behavior breaks
4. **Commit after each working milestone** - User can request commits at stable points

## Clarification Process

Before starting any step, Claude should:

1. **Inspect the current implementation first** - Read the relevant sections of `window_filter.lua` to understand how the existing code handles the functionality being implemented. This is the source of truth for behavioral requirements.

2. **Check the technical reference** - Read `window_filter-rewrite-info.md` for data structure specs and API details.

3. **Ask the user only for unresolved questions** - If the current implementation doesn't clarify something, or if there's a design decision that differs from the original, ask the user before proceeding.

This ensures implementation matches existing behavior and minimizes back-and-forth.

## Recommended Implementation Order

The implementation should follow this dependency order, where each step builds on the previous:

```
Step 0: Contract Tests for CURRENT implementation (defines the behavioral contract)
        ↓
Step 1: Utilities + Core data structures
        ↓
Step 2: WindowInfo + AppInfo
        ↓
Step 3: FilterRules + Filter (pure functions, including regions)
        ↓
Step 4: PreFilter
        ↓
Step 5: Events + Subscriptions
        ↓
Step 6: Tracker
        ↓
Step 7: Manager (including spaces handling with eager refresh)
        ↓
Step 8a: WindowFilter Class + Events (public API, subscriptions, derived events)
        ↓
Step 8b: getWindows + Sorting + Notify
        ↓
Step 9: Default filters + module-level functions
        ↓
Step 10: Run Step 0 tests against new implementation + performance validation
```

## Step-by-Step Implementation Details

### Step 0: Contract Tests (~300 lines) ✓ COMPLETE

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

function testSetRegions()
  local f = wf.new()
  local screen = hs.screen.mainScreen()
  local result = f:setRegions(screen:frame())
  assertIsEqual(f, result)
  f:delete()
  return success()
end

-- ============================================================================
-- KNOWN BUG TESTS (these document bugs in current implementation)
-- ============================================================================
-- NOTE: The testRejectRegionsBug test is SKIPPED in Step 0 contract tests.
-- It will be added in Step 10 when verifying the fix in the new implementation.
-- See Section 7 of window_filter-rewrite-plan.md for bug details.
-- ============================================================================

--[[ SKIPPED FOR STEP 0 - Add this test in Step 10:
-- This test documents the rejectRegions bug in the current implementation.
-- The current code incorrectly uses filter.allowRegions instead of filter.rejectRegions.
-- This test will FAIL against the buggy current implementation but PASS against the fixed rewrite.
function testRejectRegionsBug()
  -- This test requires a visible window, so ensure one exists
  hs.openConsole()
  local win = hs.window.focusedWindow()
  if not win then
    print('    SKIP: No focused window available')
    return success()
  end

  local frame = win:frame()

  -- Create a region that DOES contain the window (allowRegions would match)
  local containingRegion = hs.geometry.rect(frame.x - 10, frame.y - 10, frame.w + 20, frame.h + 20)

  -- Create a region that does NOT contain the window (for rejectRegions)
  local nonContainingRegion = hs.geometry.rect(frame.x + frame.w + 1000, frame.y + frame.h + 1000, 100, 100)

  -- Test: rejectRegions with non-containing region should ALLOW the window
  local f = wf.new(true):setOverrideFilter({
    visible = true,
    rejectRegions = nonContainingRegion
  })
  local allowed = f:isWindowAllowed(win)

  -- BUG: Current implementation checks allowRegions (nil) instead of rejectRegions
  -- So it incorrectly allows ALL windows regardless of rejectRegions setting
  -- The fix should make this test pass by correctly rejecting windows IN rejectRegions

  -- For now, we just verify the API accepts rejectRegions without error
  assertIsBoolean(allowed)
  f:delete()
  return success()
end
--]]
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

### Step 1: Utilities + Core Constants (~100 lines) ✓ COMPLETE

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

### Step 2: WindowInfo + AppInfo (~150 lines) ✓ COMPLETE

**What to implement:**
- `WindowInfo.new(hsWindow)` - Safe property extraction
- `WindowInfo:refresh()` - Update mutable properties
- `AppInfo.new(hsApp, pid)` - Safe property extraction

**Design Decisions:**

1. **WindowInfo.appName/appPid**: NOT set in `WindowInfo.new()`. These are set by Tracker after construction (`windowInfo.appName = appInfo.name`). This maintains separation of concerns - WindowInfo extracts window properties, Tracker associates them with apps.

2. **Timestamps for sorting**: WindowInfo includes:
   - `timeCreated` - set to `hs.timer.absoluteTime()` in `WindowInfo.new()`
   - `timeFocused` - initialized to 0, updated by Tracker on focus events
   This ensures sort comparators work correctly from the start.

3. **role field**: Uses `hsWindow:subrole()` (not `role()`). The existing implementation checks subrole against ALLOWED_ROLES (AXStandardWindow, AXDialog, AXSystemDialog). Field is named `role` in WindowInfo for clarity.

4. **AppInfo.windows**: Initialized as empty `{}` in `AppInfo.new()`. Tracker populates it via `registerAppWindows()` and `registerWindow()`. AppInfo doesn't enumerate windows itself.

5. **Testing exposure**: Expose `_WindowInfo` and `_AppInfo` with `_` prefix for development testing. Contract tests (Step 10) validate through public API.

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

### Step 3: FilterRules + Filter (~200 lines) ✓ COMPLETE

**What to implement:**
- `FilterRules.new()` - Rule storage
- `Filter.matches(rules, windowInfo, context)` - Main matching logic
- `Filter.matchesRule(rule, windowInfo, context)` - Single rule matching
- All rule criteria: visible, currentSpace, fullscreen, focused, activeApplication, hasTitlebar, allowTitles, rejectTitles, allowRoles, allowScreens, rejectScreens, allowRegions, rejectRegions

**Design Decisions (Step 3):**

1. **isInCurrentSpace on WindowInfo**: Added `isInCurrentSpace` field to WindowInfo (initialized to `nil`). Tracker will maintain this field. Filter checks it directly without needing it in context.

2. **Context shape**: Minimal context passed to Filter: `{focusedWindowId, activeAppPid}`. No global state references.

3. **Screen resolution**: Screens resolved lazily at match time via `Filter.resolveScreens()` using `hs.screen.find()`. This handles hot-plugging better than eager resolution.

4. **rejectRegions bug fixed**: The original implementation had a bug on line 228 where it used `filter.allowRegions` instead of `filter.rejectRegions`. Fixed in the new implementation.

5. **allowRoles normalization**: Handles string, array, set, or `'*'` formats for allowRoles. Normalizes to set internally for consistent lookup.

**Tests to write first:**
```lua
Test.describe('Filter', function()
    Test.it('matches visible=true', ...)
    Test.it('matches allowTitles number', ...)
    Test.it('matches allowTitles pattern', ...)
    Test.it('rejects with rejectTitles', ...)
    -- etc for each criterion
end)
```

**Why regions are included here:**
- Regions are part of the core Filter logic
- The `matchesRegions` function is a pure function with no dependencies
- Including it now allows testing the complete filter logic early
- Deferred functionality only means we don't implement space/screen *watchers* yet

**Exit criteria:** All filter criteria work correctly with mock WindowInfo

---

### Step 4: PreFilter (~100 lines) ✓ COMPLETE

**What to implement:**
- `PreFilter.shouldTrack(hsWindow, hsApp, config)` - Window tracking decision
- `PreFilter.shouldTrackApp(hsApp, config)` - App tracking decision
- Configuration options for bundle ID blacklist, app name blacklist, title/role requirements

**Design Decisions (Step 4):**

1. **Separate functions**: `shouldTrackApp` checks app-level only, `shouldTrack` checks window-level only. Tracker calls them separately to avoid duplicate checks.

2. **Config as parameter**: Config passed explicitly, not referenced from module globals. Keeps functions pure and testable.

3. **ignoreAppPattern**: Made configurable instead of hard-coded. Default is `'^QTKitServer%-'` to match current behavior.

4. **app:kind() check**: Added to `shouldTrackApp` - rejects apps with `kind < 0` (non-GUI apps).

5. **defaultConfig()**: Helper function to create standard config structure.

6. **requireTitle defaults to false**: Empty-title windows are common (dialogs, new windows, palettes). If PreFilter rejects them, we won't create watchers and will miss title changes. Title filtering should happen at Filter level via `allowTitles`, not PreFilter level.

**Integration notes for later steps:**
- **Step 6 (Tracker)**: Call `shouldTrackApp` before creating app watchers, `shouldTrack` before window watchers. Pass config with `ignoreAppNames = windowfilter.ignoreAlways`.
- **Step 9**: Implement `windowfilter.isGuiApp(appname)` using the same logic (check ignoreAlways + ignoreAppPattern), not duplicating it.

**Exit criteria:** PreFilter correctly filters apps/windows before watcher creation

---

### Step 5: Events + Subscriptions (~100 lines) ✓ COMPLETE

**What to implement:**
- Event constants (windowCreated, windowDestroyed, etc.)
- `Subscriptions.new()` - Subscription storage
- `Subscriptions:add(event, fn)`, `:remove(event, fn)`, `:emit(event, window, appName)`

**Design Decisions (Step 5):**

1. **Event validation**: `Subscriptions:add()` validates that the event is a known constant and throws an error for invalid events. This catches typos immediately rather than silently failing.

2. **Callback validation**: `Subscriptions:add()` also validates that the callback is a function, erroring otherwise.

3. **pcall protection in emit**: All user callbacks are wrapped in pcall. Errors are logged with `[wfilter] callback error for <event>: <message>` and don't prevent other callbacks from running.

4. **Safe iteration during emit**: Callbacks are copied to a list before iteration to handle self-unsubscribe during emit. Each callback is checked if still subscribed before calling (in case an earlier callback removed it).

5. **Duplicate prevention**: Adding the same function twice for the same event returns false and doesn't create a duplicate entry (callbacks stored as set `{[fn] = true}`).

6. **Sort order constants included**: The `sortByFocused`, `sortByFocusedLast`, `sortByCreated`, `sortByCreatedLast` constants are defined in this step alongside event constants since they're simple module-level vocabulary.

7. **Helper methods**: Added `hasAny()`, `hasEvent(event)`, and `count(event)` for Manager to check subscription state without accessing internals.

**Exit criteria:** Event system works in isolation ✓

---

### Step 6: Tracker (~300 lines) ✓ COMPLETE

**What to implement:**
- `Tracker.new(manager)` - Create tracker
- `Tracker:start()`, `:stop()` - Lifecycle
- `Tracker:registerApp(hsApp)`, `:unregisterApp(pid)` - App management
- `Tracker:registerWindow(hsWindow, appInfo)`, `:unregisterWindow(windowInfo, appInfo)` - Window management
- Event handlers for app/window events
- Zombie cleanup
- `ManagerStub` - Minimal stub for testing Tracker in isolation

**Design Decisions (Step 6):**

1. **Manager interface**: Tracker defines a clear callback interface that Manager must implement:
   - `onWindowCreated(windowInfo, appInfo)`
   - `onWindowDestroyed(windowInfo, appInfo)`
   - `onWindowMoved(windowInfo, appInfo)`
   - `onWindowMinimized(windowInfo, appInfo)`
   - `onWindowUnminimized(windowInfo, appInfo)`
   - `onWindowTitleChanged(windowInfo, appInfo)`
   - `onAppActivated(appInfo)`
   - `onAppDeactivated(appInfo)`
   - `onAppHidden(appInfo)`
   - `onAppUnhidden(appInfo)`
   - `onFocusChanged(windowInfo, appInfo, prevWindowInfo)`

   ManagerStub implements these as event recording for testing.

2. **Simple events only**: Tracker reports raw OS events. It does NOT handle:
   - Event chaining (windowCreated → windowVisible → windowOnScreen)
   - Pseudo-events (windowAllowed, windowRejected)
   - Filter status changes

   Manager (Step 7) handles state transitions and derived events.

3. **Focus state**: Tracker tracks `focusedWindowId` and `focusedAppPid` internally for change detection, notifies Manager via `onFocusChanged()`. Manager will own the authoritative state for filtering context.

4. **Debouncing in Tracker**: Per-window debounce timers for `windowMoved` and `titleChanged` (using Config.MOVED_DEBOUNCE and Config.TITLE_DEBOUNCE = 0.5s). Timers stored in `movedTimers`/`titleTimers` tables keyed by windowId and cancelled on window destruction.

5. **WindowInfo updates before notify**: Tracker calls `windowInfo:refresh()` before notifying Manager for move/title events, ensuring Manager always sees current state.

6. **Error handling**: All Manager callbacks wrapped in pcall via `_notifyManager()`. Tracker logs errors but doesn't crash if Manager has bugs.

7. **Watcher lifecycle**: Careful cleanup on `stop()`:
   - Stop all per-window watchers
   - Stop all per-app watchers
   - Stop app watcher
   - Cancel all pending retry timers (`pendingApps`, `pendingWindows`)
   - Cancel all debounce timers (`movedTimers`, `titleTimers`)

8. **PreFilter integration**: Uses `PreFilter.shouldTrackApp()` and `PreFilter.shouldTrack()` from Step 4 to decide whether to create watchers. Config retrieved via `_getPreFilterConfig()` with fallback to `PreFilter.defaultConfig()`.

9. **Watcher API usage**: Watcher creation and start must use pcall wrappers (not safeCall) because `app:newWatcher()` and `watcher:start()` don't follow the typical `method(self, ...)` signature pattern.

10. **Test isolation**: Tests avoid calling `tracker:start()` which registers all 100+ running apps. Instead, tests manually set `tracker.running = true` and register individual apps for faster, more reliable testing.

**Exit criteria:** Tracker correctly manages app/window lifecycle, reports events to ManagerStub ✓

---

### Step 7: Manager (~150 lines)

**What to implement:**
- `Manager.getInstance()` - Singleton access
- `Manager:activate(wf)`, `:deactivate(wf)` - Instance management
- `Manager:getContext()` - Current focus/active app (delegates to Tracker)
- Event routing to active instances
- Spaces handling with eager refresh (using `hs.spaces.watcher`)

**Design Decisions (Step 7):**

1. **Singleton lifecycle (Lazy)**: Start Tracker when first instance activates, stop when last deactivates. No wasted resources when no filters are active.

2. **Event routing kept simple**: Manager routes raw Tracker events to instances via a single method: `instance:_handleTrackerEvent(eventType, windowInfo, appInfo)`. Manager does NOT handle event chaining or pseudo-events - that complexity is deferred to Step 8 (WindowFilter class).

3. **Window state per instance (Distributed)**: Each WindowFilter instance tracks its own allowed windows. Manager doesn't maintain per-instance window state. Different filters have different allowed sets, so this is the natural place for that state.

4. **Spaces refresh scope (Both behaviors)**: On space change:
   - Always refresh space-aware instances (`currentSpace` filter set)
   - Also refresh all active instances if `forceRefreshOnSpaceChange` is true
   - This matches current implementation behavior exactly

5. **Context from Tracker**: Manager's `getContext()` delegates to Tracker's state (`focusedWindowId`, `focusedAppPid`). Single source of truth, no sync issues.

6. **Manager callback interface**: Manager implements Tracker's callback interface (onWindowCreated, onWindowDestroyed, etc.) and translates each to a call to `_handleTrackerEvent()` on all active instances.

7. **Spaces watcher ownership**: Manager owns the `hs.spaces.watcher`. It starts when Manager starts (first instance activates) and stops when Manager stops (last instance deactivates).

**Spaces handling:**
- Use `hs.spaces.watcher` to detect space changes
- On space change, call `_handleSpaceChange()` on relevant instances
- The `forceRefreshOnSpaceChange` module variable controls whether non-spaces-aware filters also refresh

**Manager's focused responsibilities:**
1. Singleton access (`getInstance()`)
2. Tracker lifecycle (lazy start/stop based on active instance count)
3. Instance registration (`activate`/`deactivate`)
4. Spaces watcher lifecycle
5. Route Tracker callbacks to active instances via `_handleTrackerEvent()`
6. Provide context getter (delegates to Tracker)

**Exit criteria:** Manager coordinates tracker and instances correctly ✓

---

### Step 8a: WindowFilter Class + Events (~200 lines) ✓ COMPLETE

**What to implement:**
- `WF.new(fn, logname, loglevel)` - All constructor forms (nil, true, false, string, table, function)
- Filter configuration methods: `setAppFilter`, `setDefaultFilter`, `setOverrideFilter`, `setFilters`, `getFilters`, `allowApp`, `rejectApp`
- Query methods: `isAppAllowed`, `isWindowAllowed`
- Configuration: `setSortOrder`, `setCurrentSpace`, `setScreens`, `setRegions`
- Lifecycle: `pause`, `resume`, `delete`, `keepActive`, `copy`
- Subscriptions: `subscribe`, `unsubscribe`, `unsubscribeAll`
- Event handling: `_handleTrackerEvent()` with state tracking
- Derived events (windowVisible, windowOnScreen, etc.) and pseudo-events (windowAllowed, windowRejected)
- Manager integration (activate on subscribe/keepActive, deactivate on delete)

**Design Decision: State Tracking for Events (Option B)**

We track window state to emit derived events correctly. When a window is created visible, both `windowCreated` AND `windowVisible` fire. This maintains API compatibility - users subscribing to `windowVisible` expect it to fire for all visible windows, including newly created ones.

State tracked per window:
- allowed (passes filter)
- visible (not hidden by app hide)
- onScreen (not minimized, has frame)
- inCurrentSpace (if tracking spaces)

On each event, compare old vs new state and emit appropriate derived events.

**Custom filter function handling:**
```lua
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
```

**Key point:** Custom filter functions are called per-window at query time, not used for early filtering. This preserves the flexibility users expect.

**Exit criteria:** Event subscriptions work, derived events fire correctly, filter configuration works

---

### Step 8b: getWindows + Sorting + Notify (~100 lines) ✓ COMPLETE

**What to implement:**
- `getWindows([sortOrder])` - Return filtered windows with sorting
- `notify(fn, fnEmpty, immediate)` - Callback when window list changes (uses getWindows internally)
- Sort order handling using `setSortOrder` configuration
- Timestamp tracking for sorting

**Design Decisions:**

1. **Timing data for sorting**: Track timestamps in WindowFilter's `_windows` state per window.
   - `timeCreated`: Set when window first enters `_windows` (passes filter for first time)
   - `timeFocused`: Updated on each `windowFocused` event for that window
   - Each WindowFilter needs independent timestamps - a window focused while rejected by filter A shouldn't update filter A's focus time

2. **Window source**: Return windows from `self._windows` (the state table).
   - This matches the original where `getWindows()` returns currently-allowed windows
   - The state is already populated by our event handling

3. **One-shot mode**: Match original behavior exactly.
   ```lua
   -- Pattern from original:
   local wasActive = activeInstances[self]
   start(self)  -- activate if needed
   local wins = getWindowObjects(self, sortOrder)
   if not wasActive then self:pause() end
   return wins
   ```
   - Users expect `wf.new('Safari'):getWindows()` to work without explicit subscribe/keepActive
   - Temporary activation populates `_windows`, then we pause

4. **Sorting comparators**: Match original exactly.
   - `sortByFocusedLast`: most recently focused first (default)
   - `sortByFocused`: least recently focused first
   - `sortByCreatedLast`: newest first
   - `sortByCreated`: oldest first

5. **Module-level callable**: Deferred to Step 9.
   - `windowfilter(...)` → `windowfilter.new(...):getWindows()` is a module feature

**Note on potential future optimization:**

The current implementation has characteristics worth noting:
1. **Synchronous/blocking** - iterates all windows and sorts on every call
2. **No caching** - repeated calls redo all work

Future optimization opportunities (deferred to avoid scope creep):
- Caching sorted results until state changes
- Lazy sorting (only sort if sort order specified)

**Exit criteria:** `getWindows()` returns correctly filtered and sorted windows; `notify()` works correctly; matches original behavior

---

### Step 9: Default Filters + Module Functions (~120 lines) ✓ COMPLETE

**What to implement:**
- `windowfilter.default` - Lazy singleton
- `windowfilter.defaultCurrentSpace` - Lazy singleton
- `windowfilter.copy(wf)` - Deep copy
- `windowfilter.ignoreAlways` - Default blacklist
- `windowfilter.ignoreInDefaultFilter` - Additional defaults
- `windowfilter.allowedWindowRoles` - Default roles
- Direction methods: windowsToEast/West/North/South, focusWindowEast/West/North/South
- Module-level focus functions: focusEast/West/North/South
- `windowfilter.switchedToSpace(n)` - Manual space notification
- `windowfilter.forceRefreshOnSpaceChange` - Configuration
- `windowfilter.iswf(t)` - Check if value is a windowfilter
- ~~`windowfilter.isGuiApp(name)`~~ - NOT IMPLEMENTED (not needed internally, was only used by _showCandidates debug function)
- `windowfilter.setLogLevel(lvl)` - Set log level
- `windowfilter.startBatchOperation()` / `stopBatchOperation(id)` - Batch operation helpers
- Module callable via `__call` metamethod: `windowfilter(...)` → `windowfilter.new(...):getWindows()`

**Exit criteria:** Module is feature-complete, all contract tests pass

---

### Step 10: Contract Verification + Performance (~50 lines of tests)

**Purpose**: The final gate. Run the Step 0 contract tests against the new implementation to verify API compatibility.

**What to do:**

1. **Run contract tests against new implementation:**
```lua
-- In Hammerspoon console, load the new implementation
local wf_new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')

-- Temporarily replace hs.window.filter for testing
local wf_old = hs.window.filter
hs.window.filter = wf_new

-- Run the contract tests
dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua')

-- Restore original
hs.window.filter = wf_old
```

2. **Run performance benchmarks:**
```lua
-- Performance tests
local wf_new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')

local function benchmark(name, fn, iterations)
    iterations = iterations or 100
    collectgarbage('collect')

    local start = hs.timer.absoluteTime()
    for i = 1, iterations do
        fn()
    end
    local elapsed = (hs.timer.absoluteTime() - start) / 1e9

    print(string.format('%s: %.3fms avg (target varies)',
        name, elapsed / iterations * 1000))
end

local f = wf_new.new():keepActive()
benchmark('getWindows (warm)', function() f:getWindows() end, 100)
f:delete()
```

3. **Side-by-side comparison:**
```lua
local old = hs.window.filter
local new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')

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

## Session Management

Each step above is designed to be completable in a **single Claude session**. However, context may be limited, so:

1. **At session end**: Ensure code is in a working state (tests pass)
2. **At session start**: Read this plan document and relevant test files
3. **Resumption prompt**: "Continue implementing window_filter rewrite from Step N"

## Development Without Disrupting User's Hammerspoon

**CRITICAL:** The user's running Hammerspoon must remain fully functional during all development steps.

### How It Works

1. **User's running Hammerspoon:** Uses `hs.window.filter` from the installed app - never modified during development.

2. **New implementation:** Created as `window_filter_new.lua` in the source repo - a completely separate file.

3. **Testing new code:** Load the new module separately without replacing the system one:
   ```lua
   -- Load new implementation (does NOT affect hs.window.filter)
   local wf_new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')

   -- Test it
   local f = wf_new.new()
   print(f:getWindows())
   f:delete()
   ```

4. **Contract tests:** Only in Step 10, temporarily swap `hs.window.filter` to run the full contract test suite against the new implementation. Ask user permission first.

### Per-Step Testing Pattern

For Steps 1-9, use this pattern to test new code:

```lua
-- Via hs CLI:
/Users/dmg/bin/osx/hs -c '
local wf_new = dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua")
-- Run specific tests against wf_new
print(wf_new.someFunction())
'
```

The user can continue using Hammerspoon normally throughout development.

---

## File Organization During Development

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

## Parallel Development Strategy

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

## API Compatibility Verification Script

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

## Rollback Strategy

If a step introduces bugs:

1. Tests should catch it before proceeding
2. If bugs found later, git revert to last working commit
3. Each step should have its own commit with clear message:
   - "wf-rewrite: Step 1 - test framework and utilities"
   - "wf-rewrite: Step 2 - WindowInfo and AppInfo"
   - etc.

## When to Ask for User Input

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

## Example Session Flow

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
