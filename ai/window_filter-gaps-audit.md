# window_filter_new.lua — Gaps Audit

Date: 2026-04-25

Audit of declared-but-unimplemented features in `window_filter_new.lua`.
Two issues (z-order bootstrap and hasWindow/hasNoWindows) were already fixed
prior to this report.

## 1. Events Declared but Never Emitted

### windowFullscreened / windowUnfullscreened

- **Declared**: lines 1087, 1092
- **Registered in validEvents**: yes (lines 1217-1218)
- **Emitted**: never

No logic exists to detect fullscreen transitions. The window watcher
subscribes to `windowMoved` and `windowResized` UI events, but there is
no state machine that compares the window frame to the screen frame
(or checks `hs.window:isFullScreen()`) to derive fullscreen state changes.

The original `window_filter.lua` tracks fullscreen state via
`win:isFullScreen()` and emits these events when the value changes.

### windowUnhidden

- **Declared**: line 1107
- **Registered in validEvents**: yes (line 1221)
- **Emitted**: never

The `_handleAppEvent` method (line 3561) emits `'windowShown'` for the
`appUnhidden` case, but `windowShown` is **not** a declared constant and
is **not** in the `validEvents` table. The correct event name per the
public API is `windowUnhidden`.

This means:
- `subscribe('windowUnhidden', fn)` — accepted but callback never fires
- `subscribe('windowShown', fn)` — rejected by validation (not in validEvents)

**Fix**: Change `'windowShown'` to `'windowUnhidden'` in `_handleAppEvent`.

## 2. Events Emitted but Never Declared

### windowShown

- **Emitted**: line 3561 (`self:_emitEvent('windowShown', ...)`)
- **Declared as constant**: no
- **In validEvents**: no

This is the flip side of the `windowUnhidden` issue above. The emitted
event name doesn't match any public constant, so subscribers can never
receive it.

## 3. Methods That Store Data but Never Apply It

### setScreens(screens)

- **Declared**: line 3026
- **Stores**: `self._allowedScreens`
- **Calls**: `_refreshAllWindows()`
- **Consulted during filtering**: never

`_computeWindowState()` (lines 3414-3455) does not check
`self._allowedScreens`. The value is stored and copied on `clone()`, but
the filtering logic ignores it entirely.

The original `window_filter.lua` checks the window's screen against the
allowed screens list during its filter evaluation.

### setRegions(regions)

- **Declared**: line 3044
- **Stores**: `self._allowedRegions`
- **Calls**: `_refreshAllWindows()`
- **Consulted during filtering**: never

Same situation as `setScreens` — stored but never applied during window
state computation.

Note: `Filter:matchWindow()` **does** support `allowRegions` and
`rejectRegions` in per-app/override rules (lines 591-618). The gap is
that `setRegions()` sets a WindowFilter-level region constraint that is
separate from per-app rules, and that constraint is never passed down
to the filter matching logic.

## 4. Items Verified as Properly Implemented

The following were checked and are working correctly:

- **Event constants**: windowCreated, windowDestroyed, windowMoved,
  windowMinimized, windowUnminimized, windowHidden, windowVisible,
  windowNotVisible, windowFocused, windowUnfocused, windowTitleChanged,
  windowAllowed, windowRejected, windowOnScreen, windowNotOnScreen,
  windowInCurrentSpace, windowNotInCurrentSpace, hasWindow, hasNoWindows,
  windowsChanged
- **Module variables**: allowedWindowRoles, ignoreAlways,
  ignoreInDefaultFilter
- **Public methods**: all constructor forms, setAppFilter, setDefaultFilter,
  setOverrideFilter, getFilters, isWindowAllowed, getWindows, subscribe,
  unsubscribe, pause/resume, delete, keepActive, setCurrentSpace, notify,
  copy

## Priority Recommendation

1. **windowUnhidden naming** (easy fix, one line) — subscribers for this
   event are silently broken
2. **setScreens / setRegions** (medium) — public API methods are no-ops,
   users relying on them get no filtering
3. **windowFullscreened / windowUnfullscreened** (larger) — requires
   adding fullscreen state tracking to the window state machine
