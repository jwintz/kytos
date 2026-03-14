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

### Signing, Packaging & Notarization

The full distribution workflow builds a Release `.app`, signs it with a Developer ID certificate, wraps it in a DMG, and submits to Apple for notarization.

**Requirements:**
- A "Developer ID Application" certificate in Keychain (check with `security find-identity -v -p codesigning | grep "Developer ID"`)
- An app-specific password for your Apple ID (generate at [appleid.apple.com](https://appleid.apple.com/account/manage) under Sign-In and Security > App-Specific Passwords)

**Full pipeline:**

```bash
export SIGN_IDENTITY="Developer ID Application: Your Name (TEAM_ID)"
export APPLE_ID="your@apple.id"
export APPLE_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export APPLE_TEAM_ID="YOUR_TEAM_ID"

git tag v0.1.0          # DMG filename uses git describe
pixi run sign           # → build-release → package → sign
pixi run dmg            # → Kytos-0.1.0.dmg
pixi run notarize       # → submit, wait, staple
```

**Build details:**
- `build-release` passes `ARCHS=arm64` (GhosttyKit is arm64-only) and `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` (strips `com.apple.security.get-task-allow` which blocks notarization)
- `sign` with a `SIGN_IDENTITY` signs each Mach-O binary individually with `--options runtime --timestamp` (hardened runtime + secure timestamp, both required by notarization)
- Without `SIGN_IDENTITY`, `sign` defaults to ad-hoc (`codesign --force --deep --sign -`) for local testing

**Individual steps:**

```bash
pixi run package          # Build Release + copy .app to project root
pixi run sign             # Ad-hoc sign (or set SIGN_IDENTITY for distribution)
pixi run dmg              # Create Kytos-<version>.dmg
pixi run notarize         # Submit DMG, wait for Apple, staple ticket
pixi run changelog        # Generate changelog since last git tag
```

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

On relaunch, Kytos uses a hybrid approach:

- `KytosAppDelegate` opts into secure restoration with `applicationSupportsSecureRestorableState`
- each live `NSWindow` is marked restorable by `WindowRegistrar` (sets `isRestorable`, `tabbingIdentifier`, frame autosave)
- SwiftUI restores the `UUID` presentation value for each `WindowGroup` scene
- macOS restores individual windows but does NOT reliably restore tab grouping across relaunches
- Kytos saves tab groups (`KytosAppModel_TabGroups_v1`) at shutdown and replays them via `addTabbedWindow` after windows register

Tab restoration uses a retry loop (`attemptPendingTabRestoration`) that fires every 0.1s (up to 40 attempts). It waits for all windows in a group to be registered, orders them front, then tabs them. If native restoration already grouped them, it detects this and skips.

When debugging restoration, remember that:

- a native tab is still just another `NSWindow` instance managed by AppKit
- the workspace UUID is the durable key that reconnects a restored window to `KytosAppModel.windows`
- UUID remapping happens in `workspace(for:)` when SwiftUI assigns a new UUID on restore; `restoredWindowIDRemap` and `remapPendingTabGroups` keep tab groups consistent
- `addTabbedWindow` silently fails if windows aren't visible; the retry loop orders them front first

### Widget Refresh Behavior

Kytos writes a JSON snapshot for the widget and immediately calls `WidgetCenter.shared.reloadAllTimelines()`, but WidgetKit still caches aggressively on macOS.

The main app is not sandboxed; the widget is sandboxed (via `ENABLE_APP_SANDBOX: YES`). The app writes the snapshot directly into the widget's sandbox container at `~/Library/Containers/me.jwintz.Kytos.KytosWidget/Data/Library/Application Support/Kytos/widget-snapshot.json`. The widget reads from its own Application Support directory, which resolves to the same file.

**Important**: Post-build scripts must NOT modify the widget's Info.plist after code signing — this invalidates the signature and causes pluginkit to reject the extension with "plug-ins must be sandboxed". Bundle versions are set via `CURRENT_PROJECT_VERSION` / `MARKETING_VERSION` build settings instead.

For development builds, the post-build "Register widget" script calls `pluginkit -r` / `pluginkit -a`, and `pixi run run` also registers via `lsregister` before launching.

If macOS still shows stale widget UI after a rebuild, remove and re-add the widget from the desktop gallery.

## Widget Development

Force-reload widget after rebuild (kills cached process and re-registers extension):
```bash
killall KytosWidget 2>/dev/null; pluginkit -e use -i me.jwintz.Kytos.KytosWidget
```

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
