# Kytos

A terminal emulator for macOS built on [libghostty](https://github.com/ghostty-org/ghostty) and [KelyphosKit](../kelyphos).

## Prerequisites

- macOS 26+ (Tahoe)
- [pixi](https://pixi.sh) package manager
- Xcode with macOS 26 SDK
- Ghostty source at `~/Syntropment/ghostty` (for building GhosttyKit)

## Quick Start

```bash
pixi run build    # Build GhosttyKit + generate Xcode project + compile
pixi run run      # Build if needed + launch the app
```

## Build Tasks

All build operations use `pixi run <task>`. Run `pixi task list` to see all available tasks.

| Task | Description |
|------|-------------|
| `build-ghostty` | Build `GhosttyKit.xcframework` from Ghostty source (zig + arm64) |
| `generate` | Regenerate the Xcode project from `project.yml` (XcodeGen) |
| `generate-if-needed` | Regenerate only when `project.yml` is newer than the project |
| `build` | Full build: ghostty + generate + xcodebuild (Debug) |
| `build-if-needed` | Incremental build — skips if binary is up to date |
| `run` | Build if needed + launch `Kytos.app` |
| `test` | Run `Scripts/run-tests.sh` against the `Kytos-Tests` scheme |
| `distclean` | Remove all build artifacts for a pristine rebuild |

### Release & Distribution

| Task | Description |
|------|-------------|
| `build-release` | Release configuration build |
| `package` | Copy the Release `.app` bundle to the project root |
| `sign` | Code sign the app (ad-hoc by default, set `SIGN_IDENTITY` for distribution) |
| `dmg` | Create a DMG disk image |
| `notarize` | Submit DMG for Apple notarization (requires `APPLE_ID`, `APPLE_PASSWORD`, `APPLE_TEAM_ID`) |
| `changelog` | Generate changelog from git log since last tag |

## Architecture

| Component | Role |
|-----------|------|
| **libghostty** | Terminal emulation, Metal rendering, PTY management, splits |
| **KelyphosKit** | Shell UI — navigator, inspector, utility panels, keybindings |
| **tmux** | User-facing multiplexer (available via pixi PATH, no app integration) |

### Terminal Configuration

Terminal settings (font, colors, cursor, keybindings) are managed via Ghostty's config file:

```
~/.config/ghostty/config
```

The Settings window provides an "Open Ghostty Config" button for quick access. Kytos-specific UI preferences (e.g. horizontal margin) are separate and stored in UserDefaults.

### Source Files

```
Sources/KytosApp/
  KytosApp.swift                  # @main, window/tab management, commands
  Models.swift                    # KytosSession, KytosWorkspace, KytosAppModel
  KytosSettings.swift             # Kytos-specific UI preferences
  KytosSettingsView.swift         # Settings window
  KytosPanelViews.swift           # Inspector panels
  Splits/                         # Split tree model + recursive split views
  Ghostty/
    KytosGhosttyApp.swift         # ghostty_app_t wrapper, C callbacks
    KytosGhosttyView.swift        # ghostty_surface_t NSView, keyboard/mouse/IME
    KytosTerminalRepresentable.swift  # SwiftUI bridge (NSViewRepresentable)
Sources/KytosWidget/              # macOS widget extension + shared widget snapshot model
Sources/KytosTests/               # Unit tests
Kytos.icon/                       # macOS .icon package compiled by actool
```

### Key Patterns

- **`KytosGhosttyApp`** — `@Observable @MainActor` singleton wrapping `ghostty_app_t`. Owns config, runtime C callbacks (wakeup, action, clipboard, close), and the app tick loop.
- **`KytosGhosttyView`** — `NSView` subclass wrapping `ghostty_surface_t`. Handles Metal layer, keyboard/mouse forwarding, and IME via `NSTextInputClient`.
- **`KytosTerminalRepresentable`** — Thin `NSViewRepresentable` bridging `KytosGhosttyView` into SwiftUI.
- **`KytosWorkspace`** — `@Observable` model holding a split tree of panes plus the currently focused pane for one native window/tab.
- **`KytosAppModel`** — Manages window-to-workspace mapping, persistence, widget snapshots, and native macOS tab restoration.

### Native Windows and Tabs

Kytos uses a single SwiftUI `WindowGroup`, so native macOS windows and native tabs are both backed by `KytosWorkspace` values in `KytosAppModel.windows`.

At shutdown, Kytos persists the workspace map itself (`KytosAppModel_Windows_v7`). Each `WindowGroup(for: UUID.self)` scene also gets its bound UUID restored by SwiftUI/AppKit state restoration.

On relaunch, Kytos now relies on native macOS restoration instead of replaying saved tab groups itself:

- `KytosAppDelegate` opts into secure restoration with `applicationSupportsSecureRestorableState`
- each live `NSWindow` is marked restorable by `WindowRegistrar`
- SwiftUI restores the `UUID` presentation value for each `WindowGroup` scene, and AppKit restores native tab membership for those windows

When debugging restoration, remember that:

- a native tab is still just another `NSWindow` instance managed by AppKit
- the workspace UUID is the durable key that reconnects a restored window to `KytosAppModel.windows`
- Kytos still manually tabs *new* runtime windows for `⌘T`, but relaunch restoration is now AppKit-native instead of custom regrouping

### Widget Refresh Behavior

Kytos writes a JSON snapshot for the widget and immediately calls `WidgetCenter.shared.reloadAllTimelines()`, but WidgetKit still caches aggressively on macOS.

The app and widget share that snapshot through the App Group container `group.me.jwintz.Kytos`, so both targets must keep the App Group entitlement in sync.

For development builds, `pixi run build` and `pixi run run` now:

- stamp a fresh `CFBundleVersion` into the app and widget bundle
- re-register the widget extension with `pluginkit -r` followed by `pluginkit -a`

That gives WidgetKit a much better chance of loading the rebuilt extension. If macOS still shows stale UI after a rebuild, remove and re-add the widget from the desktop gallery.

### Shell Integration & Resource Detection

Ghostty's shell integration injects OSC escape sequences into bash/zsh/fish/elvish/nushell so the terminal receives live updates: OSC 0/2 for the process title, OSC 7 for the working directory. These drive the dynamic toolbar title/subtitle and navigator pane labels.

**Sentinel file** — On startup, libghostty walks up from the executable path looking for a **sentinel file** at:

```
<ancestor>/Contents/Resources/terminfo/78/xterm-ghostty
```

The `78/` directory is terminfo's standard hash bucket (`0x78` = `'x'`, for `xterm-ghostty`). If found, ghostty sets its `resources_dir` to `<ancestor>/Contents/Resources/ghostty`, which must contain the `shell-integration/` scripts.

For Kytos, these resources live at:

```
Kytos.app/Contents/Resources/
  terminfo/78/xterm-ghostty      ← sentinel (enables resource detection)
  ghostty/shell-integration/     ← bash, zsh, fish, elvish, nushell scripts
```

They are copied into the app bundle by the "Copy Ghostty Resources" pre-build script in `project.yml`, sourced from `Resources/` in the repo (which `pixi run build-ghostty` populates from ghostty's `zig-out/share/`).

**Default config files** — `ghostty_config_load_default_files()` (called in `KytosGhosttyApp.init`) loads the user's terminal configuration from ghostty's standard locations (`~/.config/ghostty/config`, XDG paths). This is why all terminal settings (font, colors, cursor, keybindings) are configured via ghostty's own config file rather than Kytos-specific preferences.

### Build Pipeline

1. **GhosttyKit** — Built from Ghostty source via `zig build` (arm64, ReleaseFast). Produces `Frameworks/GhosttyKit.xcframework` (static library, git-ignored).
2. **XcodeGen** — `project.yml` defines targets, dependencies, and build settings. Generates `Kytos.xcodeproj` (git-ignored).
3. **xcodebuild** — Compiles Swift 6 sources, links GhosttyKit + Carbon + KelyphosKit, produces `Kytos.app`.
