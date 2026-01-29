# hs.window.filter Rewrite Plan

**Date**: 2025-01-28
**Status**: Complete (All Steps Done)
**Target**: Full API-compatible replacement for upstream `hs.window.filter`
**Actual Size**: ~3250 lines (vs current ~2400)

**Related Documents:**
- [Technical Reference](window_filter-rewrite-info.md) - Data structures, component specs, API matrix, performance targets, test specs
- [Implementation Guide](window_filter-rewrite-plan-for-claude.md) - Step-by-step implementation guidance for Claude

---

## Progress

| Step | Description | Status | Notes |
|------|-------------|--------|-------|
| 0 | Contract Tests | **Complete** | 49 contract tests pass |
| 1 | Utilities + Core Constants | **Complete** | safeCall, Config, logging |
| 2 | WindowInfo + AppInfo | **Complete** | Safe property access wrappers |
| 3 | FilterRules + Filter | **Complete** | Pure filter matching logic |
| 4 | PreFilter | **Complete** | Bundle ID blacklist, Web Content$ pattern |
| 5 | Events + Subscriptions | **Complete** | All event types + pseudo-events |
| 6 | Tracker | **Complete** | App/window lifecycle, watchers |
| 7 | Manager | **Complete** | Singleton coordinator, keepActive |
| 8a | WindowFilter Class (Part 1) | **Complete** | Core class structure, constructors |
| 8b | WindowFilter Class (Part 2) | **Complete** | Remaining methods, direction/focus |
| 9 | Default Filters + Module Functions | **Complete** | default, defaultCurrentSpace, ignoreAlways |
| 10 | Contract Verification | **Complete** | 123 internal tests, all 49 contract tests pass |
| 11 | Performance + Behavioral Tests | **Complete** | keepActive optimization, focus/direction methods |

### Implementation Details

**Files Created:**
- `extensions/window/window_filter_new.lua` - Complete rewrite (~3250 lines)
- `extensions/window/test_window_filter.lua` - 49 contract tests
- `extensions/window/test_window_filter_internals.lua` - 123 internal component tests

**Contract Tests (49 total):**
- Constructor Tests (7): `new()`, `new(true)`, `new(false)`, `new(string)`, `new(table)`, `new({rules})`, `new(function)`
- Method Chaining Tests (5): All filter methods return `self`
- Filter Rules Tests (3): `visible`, `allowTitles`, `rejectApp`
- getWindows Tests (3): Returns table, window objects, sort orders
- Subscription Tests (5): `subscribe`, `unsubscribe`, `unsubscribeAll`, `pause`, `resume`
- Module-Level API Tests (5): `default`, `defaultCurrentSpace`, `ignoreAlways`, event constants, sort constants
- Copy Tests (1): Independent copy verification
- Edge Case Tests (7): `setFilters`, `getFilters`, `isWindowAllowed`, `keepActive`, `setCurrentSpace`, `setScreens`, `setRegions`
- Behavioral Tests (13): notify, setOverrideFilter, iswf, copy independence, batch operations, direction methods, focus methods

**Internal Tests (123 total):**
- safeCall tests
- WindowInfo tests
- AppInfo tests
- FilterRules tests
- PreFilter tests
- Events tests
- Filter matching tests
- Constructor tests
- getWindows tests

**Key Discoveries:**
1. `isAppAllowed()` returns `true` for all apps even with single-app/app-list filters - filtering happens at window level via `getWindows()`
2. `setScreens()` expects a screen name (string), not a screen object
3. `setRegions()` expects a table of regions, not a single region

**Bug Fixed:** `rejectRegions` now correctly uses `filter.rejectRegions` instead of `filter.allowRegions`

**Performance Optimizations:**
- Default filter calls `keepActive()` to maintain global watcher (avoids 0.4s cold start on each operation)
- PreFilter blacklists "Web Content$" pattern to skip browser helper processes
- Cold start: ~0.4s (once), warm operations: instant

**Development approach:** All work happened in `window_filter_new.lua`. The user's running `hs.window.filter` was never modified during development.

---

## Table of Contents

1. [Goals and Non-Goals](#1-goals-and-non-goals)
2. [Architecture Overview](#2-architecture-overview)
3. [Core Design Principles](#3-core-design-principles)
4. [Module Structure](#4-module-structure)
5. [Future Deprecation Candidates](#5-future-deprecation-candidates)
6. [Known Bugs Fixed](#6-known-bugs-fixed)

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

## 5. Future Deprecation Candidates

These API elements could be improved in a future breaking version:

### 5.1 `setAppFilter` Overloading

**Current**: `setAppFilter(name, filter)` where filter can be `false`, `true`, `nil`, or a table.

**Better**: Separate methods
```lua
:rejectApp(name)           -- Clear intent
:allowApp(name)            -- Clear intent
:setAppRules(name, rules)  -- For complex rules
```

**Migration**: Keep current API, add new methods, deprecate in v2.

### 5.2 Constructor Overloading

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

### 5.3 Pseudo-events as Separate Subscriptions

**Current**: Pseudo-events (`hasWindow`, `windowsChanged`) mixed with real events.

**Better**: Separate subscription types
```lua
:subscribe(event, fn)          -- Real events only
:onWindowsChanged(fn)          -- Aggregate changes
:onFirstWindow(fn)             -- Has window
:onNoWindows(fn)               -- Lost all windows
```

### 5.4 `forceRefreshOnSpaceChange` Global

**Current**: Module-level variable affecting all instances.

**Better**: Per-instance configuration
```lua
:setSpaceRefreshPolicy('eager'|'lazy'|'manual')
```

---

## 6. Known Bugs Fixed

### 6.1 `rejectRegions` Uses Wrong Variable

**Location**: Current `window_filter.lua` line 228

**Bug**: The `rejectRegions` check incorrectly uses `filter.allowRegions`:
```lua
-- CURRENT (BUGGY):
if filter.rejectRegions and matchRegions(filter.allowRegions,win.frame) then return false,'rejectRegions' end
                                         ^^^^^^^^^^^^^^^^^^^ WRONG

-- CORRECT:
if filter.rejectRegions and matchRegions(filter.rejectRegions,win.frame) then return false,'rejectRegions' end
```

**Status**: Fixed in `window_filter_new.lua`. The new implementation correctly uses `filter.rejectRegions`.
