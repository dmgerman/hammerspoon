# Window Filter Rewrite Plan - Review Report

**Date**: 2026-01-28
**Reviewer**: Claude (Opus 4.5)
**Plan File**: `ai/window_filter-rewrite-plan.md`
**Current Implementation**: `extensions/window/window_filter.lua` (2325 lines)

---

## 1. Summary of What I Read

The plan proposes a complete rewrite of `hs.window.filter` with the following key objectives:

- **Full API compatibility** with the current 2325-line implementation
- **Cleaner architecture** using a Manager singleton, separate Tracker, pure Filter functions, and PreFilter for early window rejection
- **Better performance** through early filtering (reducing watcher count by ~50%) and lazy space queries
- **Production-grade quality** with pcall protection for all accessibility API calls
- **Test-driven development** with contract tests written first against the current implementation

The plan is organized into 13 sections covering goals, architecture, data structures, component specifications, API compatibility matrix, performance targets, test specifications, implementation phases (10 steps), and detailed implementation guidance for Claude.

---

## 2. Consistency Assessment

### 2.1 Issues Found

#### CRITICAL: `setRegions`/`allowRegions` Marked as "Deferred" but Fully Implemented

**Problem**: Section 12 and the API matrix mark `setRegions` as "Deferred" with temporary behavior to "log warning, ignore." However, the current implementation (`window_filter.lua:416-419`, `575-580`, `227-228`) **fully implements** this feature.

**Current code** (lines 227-228):
```lua
if filter.allowRegions and not matchRegions(filter.allowRegions,win.frame) then return false,'allowRegions' end
if filter.rejectRegions and matchRegions(filter.allowRegions,win.frame) then return false,'rejectRegions' end
```

**Impact**: Deferring this would break existing users relying on `allowRegions`/`rejectRegions`.

**Recommendation**: Either implement `setRegions`/`allowRegions`/`rejectRegions` fully, OR document this as a known breaking change and check if any public Spoons use it.

---

#### BUG IN CURRENT CODE: `rejectRegions` Uses Wrong Variable

**Location**: `window_filter.lua:228`

**Bug**: The `rejectRegions` check calls `matchRegions(filter.allowRegions, ...)` instead of `matchRegions(filter.rejectRegions, ...)`:
```lua
if filter.rejectRegions and matchRegions(filter.allowRegions,win.frame) then return false,'rejectRegions' end
                                         ^^^^^^^^^^^^^^^^^^^ WRONG - should be rejectRegions
```

**Question**: Should the rewrite fix this bug? This could change behavior for users who unknowingly depend on the buggy behavior.

---

#### Test Framework Inconsistency

**Problem**: The plan references two different test patterns:

1. **Section 9.1** says tests go in `~/git.forks/hammerspoon/extensions/window/test_window_filter.lua` using Hammerspoon's built-in test framework (matching `test_window.lua` format).

2. **Section 13.3** (Step 0 example code) uses a different module pattern:
   ```lua
   local test_contract = require('test.test_contract')
   ```

3. **Section 9.2-9.3** reference internal tests via:
   ```lua
   local Filter = _G._windowFilterInternals.Filter
   ```

**Question**: Which test pattern should be used? The Hammerspoon-native format (global `testXxx()` functions returning `success()`) or a custom module-based framework?

---

#### `_G._windowFilterInternals` Global Pollution

**Problem**: The plan proposes exposing internal components via `_G._windowFilterInternals` for testing. This pollutes the global namespace.

**Question**: Is this acceptable for the Hammerspoon codebase? Alternatives:
- Only expose in debug builds
- Use a module-level `_internals` table that tests can access
- Accept that internal tests run within the module file itself

---

### 2.2 Ambiguities Requiring Clarification

#### Custom Function Filter Behavior

**Current code** (`window_filter.lua:706-711`):
```lua
if type(fn)=='function' then
    o.log.i('new',o,'- custom function')
    o.isAppAllowed = function()return true end
    o.isWindowAllowed = function(_,w) return fn(w) end
    o.customFilter=true
    return o
```

**Plan's Section 6.6** shows:
```lua
elseif type(fn) == 'function' then
    -- Custom function
    self.customFilter = fn
    return self
```

**Question**: The plan stores the function differently but doesn't show how `isWindowAllowed` and `isAppAllowed` work with custom functions. How should the pure Filter logic handle `customFilter`?

---

#### Spaces Implementation Strategy

**Current implementation** uses `hs.spaces.watcher` (line 1542) and has complex tracking in `spacesInstances`, `trackSpacesFilters`, `trackSpacesSubscriptions`.

**Plan** mentions "Lazy on-demand query" for spaces but doesn't detail:
- How `currentSpace` filter criterion is evaluated
- When space change events trigger window list refresh
- How `windowfilter.forceRefreshOnSpaceChange` interacts with lazy queries
- How `windowfilter.switchedToSpace(n)` is implemented

**Question**: Can you clarify the spaces implementation strategy?

---

#### Direction Methods Implementation

**Plan** marks `windowsToEast/West/North/South` and `focusWindowEast/West/North/South` as "Full" support but doesn't provide implementation details.

**Current implementation** (`window_filter.lua:2114-2131`) delegates to `hs.window.windowsToEast()`:
```lua
-- hs.window.filter:windowsToEast(window, frontmost, strict) -> list of `hs.window` objects
-- This is a convenience wrapper that returns `hs.window.windowsToEast(window,self:getWindows(),...)`
```

**Question**: Should the rewrite simply delegate to `hs.window` methods, or is there additional logic needed?

---

#### `keepActive()` Lifecycle

**Plan** shows `keepActive()` (line 1207-1210):
```lua
function WF:keepActive()
    self._keepActive = true
    Manager.getInstance():activate(self)
    return self
end
```

**Question**: How does `_keepActive` interact with:
- `pause()` - should pause be a no-op if keepActive is set?
- `unsubscribeAll()` - current code shows this leads to `pause()`
- `delete()` - should this clear the keepActive flag?

---

#### Screen Hint Format

**Plan** Section 6.2 mentions `rule._allowedScreenIds` and `rule._rejectedScreenIds` but doesn't specify:
- What formats `allowScreens` accepts (screen object, ID, name, geometry?)
- How screen hints are resolved to screen IDs
- Whether this resolution happens at rule-set time or match time

**Current code** (`window_filter.lua:581-585`) calls `getListOfScreens(v)` which uses `hs.screen.find()`.

**Question**: Should screen resolution happen eagerly (at setAppFilter time) or lazily (at filter match time)?

---

### 2.3 Minor Issues

1. **Line count estimate**: Plan estimates 1200-1500 lines; current is 2325. A 40-50% reduction is ambitious but achievable given the cleaner architecture.

2. **Event constant naming**: Plan shows `Events.windowCreated` but API shows `windowfilter.windowCreated`. Need to ensure module-level exports match.

3. **`window.lua` SKIP_APPS**: The `window.lua` file (lines 84-87) has its own `SKIP_APPS` table similar to `ignoreAlways`. The plan should note this isn't duplicated logic.

4. **Benchmark CI safety**: Plan uses 50ms target but test uses 100ms threshold. This is good (CI machines are slower), but should be documented explicitly.

---

## 3. Clarification Questions

Before implementation, please clarify:

1. **`setRegions`/`allowRegions`**: Should this be implemented fully (to maintain compatibility) or deferred (breaking change)? If deferred, what's the migration path for existing users?

2. **`rejectRegions` bug fix**: Should the rewrite fix the bug where `rejectRegions` incorrectly uses `filter.allowRegions`? (This is technically a behavior change.)

3. **Test framework choice**: Which test pattern should be used:
   - (A) Hammerspoon-native global `testXxx()` functions only
   - (B) Module-based with `_G._windowFilterInternals` for internal testing
   - (C) Something else?

4. **Custom filter function**: How should `Filter.matches()` handle windowfilters created with `new(function)`? The pure function approach doesn't easily accommodate user-provided filter functions.

5. **Spaces strategy**: Should the rewrite maintain the current eager-refresh-on-space-change behavior, or implement true lazy evaluation? The current `forceRefreshOnSpaceChange` and `switchedToSpace(n)` APIs suggest users expect specific behaviors.

6. **Screen resolution timing**: Should `allowScreens` resolve screen hints eagerly (at configuration time) or lazily (at filter match time)?

---

## 4. Proposed Updates to Plan

### 4.1 `setRegions` Status Change

Change Section 12 and API matrix from "Deferred" to "Full" to maintain API compatibility:

```markdown
| `:setRegions(regions)`                               | Full         |                       |
```

Add to Section 6.2 (Filter):
```lua
-- Regions (only for visible windows)
if windowInfo.isVisible then
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
end
```

### 4.2 Bug Fix Documentation

Add to Section 1 (Goals):
```markdown
5. **Bug fixes** - Fix known bugs in current implementation (e.g., rejectRegions using wrong variable)
```

### 4.3 Test Framework Clarification

Replace Section 9.1 with a single consistent approach:
```markdown
### 9.1 Test Framework

All tests use Hammerspoon's built-in test framework in `extensions/window/test_window_filter.lua`:

- Global `testXxx()` functions (CamelCase after "test")
- Built-in assertions: `assertIsEqual()`, `assertTrue()`, `assertFalse()`, etc.
- Each test returns `success()`
- Internal component tests also go in this file, accessing internals via a module-level `_internals` table (not `_G`)
```

### 4.4 Custom Filter Handling

Add to Section 6.6:
```lua
function WF:isWindowAllowed(hsWindow)
    if self.customFilter then
        local ok, result = pcall(self.customFilter, hsWindow)
        return ok and result
    end
    -- ... normal filter logic
end
```

---

## 5. Readiness Statement

**All clarifications resolved. I am ready to implement.**

Resolved decisions:
1. `setRegions`/`allowRegions`/`rejectRegions`: **Implement fully** (API compatibility)
2. `rejectRegions` bug: **Fix it** (document in tests as known bug in current implementation)
3. Test framework: **Native Hammerspoon format only** (no `_G._windowFilterInternals`)
4. Custom filter functions: **Handle at WF class level**, bypassing pure Filter for custom functions
5. Spaces strategy: **Eager refresh** for reliability (matches current behavior)
6. Screen resolution: **Lazy** at match time for reliability (handles hot-plugging)

The plan has been updated with these decisions. Implementation can begin with Step 0 (Contract Tests).

---

## 6. Summary

| Category | Status |
|----------|--------|
| Architecture | Well-designed, clear improvement over current |
| API Compatibility | Complete - all features including regions |
| Test Strategy | Native Hammerspoon format, public API testing |
| Implementation Guidance | Excellent step-by-step breakdown |
| Performance Targets | Reasonable and measurable |
| Bug Fixes | `rejectRegions` bug documented and will be fixed |

**Overall Assessment**: The plan is complete and ready for implementation. All clarifications have been resolved and the plan has been updated accordingly.
