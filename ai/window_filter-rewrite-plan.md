# hs.window.filter Rewrite Plan

**Date**: 2025-01-28
**Status**: In Progress (Step 0 Complete)
**Target**: Full API-compatible replacement for upstream `hs.window.filter`
**Estimated Size**: ~1200-1500 lines (vs current ~2400)

**Related Documents:**
- [Technical Reference](window_filter-rewrite-info.md) - Data structures, component specs, API matrix, performance targets, test specs
- [Implementation Guide](window_filter-rewrite-plan-for-claude.md) - Step-by-step implementation guidance for Claude

---

## Progress

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 0 | Contract Tests | **Complete** | 36 tests pass against current implementation |
| 1 | Utilities + Core Constants | Not Started | |
| 2 | WindowInfo + AppInfo | Not Started | |
| 3 | FilterRules + Filter | Not Started | |
| 4 | PreFilter | Not Started | |
| 5 | Events + Subscriptions | Not Started | |
| 6 | Tracker | Not Started | |
| 7 | Manager | Not Started | |
| 8 | WindowFilter Class | Not Started | |
| 9 | Default Filters + Module Functions | Not Started | |
| 10 | Contract Verification + Performance | Not Started | |

### Step 0 Details (2025-01-28)

**Created:** `extensions/window/test_window_filter.lua`

**Tests:** 36 contract tests covering:
- Constructor Tests (7): `new()`, `new(true)`, `new(false)`, `new(string)`, `new(table)`, `new({rules})`, `new(function)`
- Method Chaining Tests (5): All filter methods return `self`
- Filter Rules Tests (3): `visible`, `allowTitles`, `rejectApp`
- getWindows Tests (3): Returns table, window objects, sort orders
- Subscription Tests (5): `subscribe`, `unsubscribe`, `unsubscribeAll`, `pause`, `resume`
- Module-Level API Tests (5): `default`, `defaultCurrentSpace`, `ignoreAlways`, event constants, sort constants
- Copy Tests (1): Independent copy verification
- Edge Case Tests (7): `setFilters`, `getFilters`, `isWindowAllowed`, `keepActive`, `setCurrentSpace`, `setScreens`, `setRegions`

**Discoveries during testing:**
1. `isAppAllowed()` returns `true` for all apps even with single-app/app-list filters - filtering happens at window level via `getWindows()`
2. `setScreens()` expects a screen name (string), not a screen object
3. `setRegions()` expects a table of regions, not a single region

**Skipped:** `testRejectRegionsBug` - will be added in Step 10 to verify the fix

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Core Design Principles](#3-core-design-principles)
4. [Module Structure](#4-module-structure)
5. [Implementation Phases](#5-implementation-phases)
6. [Future Deprecation Candidates](#6-future-deprecation-candidates)
7. [Known Bugs to Fix](#7-known-bugs-to-fix)

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

## 5. Implementation Phases

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

## 6. Future Deprecation Candidates

These API elements could be improved in a future breaking version:

### 6.1 `setAppFilter` Overloading

**Current**: `setAppFilter(name, filter)` where filter can be `false`, `true`, `nil`, or a table.

**Better**: Separate methods
```lua
:rejectApp(name)           -- Clear intent
:allowApp(name)            -- Clear intent
:setAppRules(name, rules)  -- For complex rules
```

**Migration**: Keep current API, add new methods, deprecate in v2.

### 6.2 Constructor Overloading

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

### 6.3 Pseudo-events as Separate Subscriptions

**Current**: Pseudo-events (`hasWindow`, `windowsChanged`) mixed with real events.

**Better**: Separate subscription types
```lua
:subscribe(event, fn)          -- Real events only
:onWindowsChanged(fn)          -- Aggregate changes
:onFirstWindow(fn)             -- Has window
:onNoWindows(fn)               -- Lost all windows
```

### 6.4 `forceRefreshOnSpaceChange` Global

**Current**: Module-level variable affecting all instances.

**Better**: Per-instance configuration
```lua
:setSpaceRefreshPolicy('eager'|'lazy'|'manual')
```

---

## 7. Known Bugs to Fix

### 7.1 `rejectRegions` Uses Wrong Variable

**Location**: Current `window_filter.lua` line 228

**Bug**: The `rejectRegions` check incorrectly uses `filter.allowRegions`:
```lua
-- CURRENT (BUGGY):
if filter.rejectRegions and matchRegions(filter.allowRegions,win.frame) then return false,'rejectRegions' end
                                         ^^^^^^^^^^^^^^^^^^^ WRONG

-- CORRECT:
if filter.rejectRegions and matchRegions(filter.rejectRegions,win.frame) then return false,'rejectRegions' end
```

**Action**: Fix this bug in the rewrite. Add a contract test that exposes this bug against the current implementation (the test should fail against current, pass against new).
