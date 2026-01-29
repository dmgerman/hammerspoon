# Hammerspoon Development Guide

This file contains essential information for building and testing Hammerspoon.

**IMPORTANT: Never commit.** Only the user commits. Provide commit messages when asked.

## Build System Overview

Hammerspoon uses Xcode with a shell-based build wrapper script.

### Prerequisites

- **Xcode**: Must be installed and set as the active developer directory
  ```bash
  xcode-select -p  # Should show /Applications/Xcode.app/Contents/Developer
  ```
- **Homebrew**: Required for dependencies
- **coreutils**: `brew install coreutils` (provides `greadlink`, `grm`)

### Installing Dependencies

```bash
./scripts/build.sh installdeps
```

This installs:
- Homebrew packages: jq, xcbeautify, gawk, cocoapods, gh, gpg, xcresultparser
- Python packages: jinja2, mistune, pygments (for documentation)

## Building

### Debug Build

```bash
./scripts/build.sh build -c Debug
```

**Note**: The build archive will succeed, but the export step will fail without code signing certificates. This is expected for development. The built app is available at:
```
build/Hammerspoon.app.xcarchive/Products/Applications/Hammerspoon.app
```

### Release Build

```bash
./scripts/build.sh build -c Release
```

### Clean Build

```bash
./scripts/build.sh clean
```

## Testing

### Run Tests on Running Hammerspoon (Preferred for Development)

Use the `hs` CLI to run tests on a running Hammerspoon instance:

```bash
# Run a test file
/Users/dmg/bin/osx/hs -c 'dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window.lua")'

# Run individual Lua commands
/Users/dmg/bin/osx/hs -c 'return hs.window.filter.new():getWindows()'
```

This allows testing without restarting Hammerspoon.

### Formal Test Suite (CI/Full Validation)

```bash
./scripts/build.sh build -e -c Debug  # Build for testing
./scripts/build.sh test -e -c Debug   # Run XCTest suite
```

**Note**: The formal test suite launches a new Hammerspoon instance and will conflict with a running instance.

### Test Framework

Tests are Lua files in `extensions/*/test_*.lua`. They use Hammerspoon's built-in test framework:
- Global `testXxx()` functions
- Assertions: `assertIsEqual()`, `assertTrue()`, `assertFalse()`, `assertIsTable()`, `assertIsNotNil()`, `assertGreaterThan()`, `assertIsBoolean()`, `assertIsString()`, `assertIsNumber()`
- Each test returns `success()`

### Test File Locations

Test files follow the pattern `extensions/<module>/test_<module>.lua`:
- `extensions/window/test_window.lua`
- `extensions/application/test_application.lua`
- etc.

## Project Structure

```
hammerspoon/
├── Hammerspoon/              # Main app source (Objective-C)
├── Hammerspoon.xcworkspace   # Xcode workspace
├── extensions/               # Lua modules (Objective-C + Lua)
│   ├── window/
│   │   ├── window.lua
│   │   ├── window_filter.lua
│   │   ├── libwindow.m
│   │   └── test_window.lua
│   └── .../
├── LuaSkin/                  # Lua-Objective-C bridge
├── scripts/
│   ├── build.sh              # Main build script
│   └── libbuild.sh           # Build helper functions
└── Pods/                     # CocoaPods dependencies
```

## Documentation

### Build Documentation

```bash
./scripts/build.sh docs
```

Options:
- `-j` - JSON only
- `-m` - Markdown only
- `-t` - HTML only
- `-l` - Lint only (no build)

## Code Style

Follow conventions in existing code (e.g., `window.lua`):
- Local caching at top: `local pairs, ipairs, type = pairs, ipairs, type`
- Consistent spacing
- Line length ~100 chars max
- LuaDoc comments for public APIs

## Window Filter Rewrite

**Current Status:** Step 7 Complete (Manager)

**IMPORTANT:** Development happens in `window_filter_new.lua` - the user's running Hammerspoon (`hs.window.filter`) is never affected. Test new code by loading it separately:
```lua
local wf_new = dofile('/Users/dmg/git.forks/hammerspoon/extensions/window/window_filter_new.lua')
-- test wf_new, not hs.window.filter
```

See `ai/` directory for rewrite planning documents:
- `ai/window_filter-rewrite-plan.md` - Main plan + progress tracking
- `ai/window_filter-rewrite-info.md` - Technical reference
- `ai/window_filter-rewrite-plan-for-claude.md` - Implementation guidance

**Test files:**
- `extensions/window/test_window_filter.lua` - Contract tests (36 tests, public API)
- `extensions/window/test_window_filter_internals.lua` - Internal tests (86 tests, new impl components)

Run tests:
```bash
/Users/dmg/bin/osx/hs -c 'dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter.lua")'
/Users/dmg/bin/osx/hs -c 'dofile("/Users/dmg/git.forks/hammerspoon/extensions/window/test_window_filter_internals.lua")'
```
