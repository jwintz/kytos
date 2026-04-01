# Kytos

A terminal emulator for macOS built on [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) and [KelyphosKit](https://github.com/jwintz/kelyphos).

**[Documentation](https://jwintz.github.io/kytos)**

## Prerequisites

- macOS 26+ (Tahoe)
- [pixi](https://pixi.sh) package manager
- Xcode with macOS 26 SDK

## Quick Start

```bash
pixi run build    # Generate Xcode project + compile
pixi run run      # Build if needed + launch the app
```

## Build Tasks

All build operations use `pixi run <task>`. Run `pixi task list` to see all available tasks.

| Task | Description |
|------|-------------|
| `generate` | Regenerate the Xcode project from `project.yml` (XcodeGen) |
| `generate-if-needed` | Regenerate only when `project.yml` is newer than the project |
| `build` | Full build: generate + xcodebuild (Debug) |
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
- `build-release` passes `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` (strips `com.apple.security.get-task-allow` which blocks notarization)
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
| **SwiftTerm** | Terminal emulation, PTY management, text rendering (via SPM) |
| **KelyphosKit** | Shell UI — navigator, inspector, utility panels, keybindings |

### Terminal Configuration

Terminal appearance (font, colors, cursor) is managed by Kytos internally. The default font is SF Mono 13pt with a dark/light ANSI color palette that follows the system appearance. Kytos-specific UI preferences (e.g. horizontal margin, focus-follows-mouse) are stored in UserDefaults.

### Source Files

```
Sources/KytosApp/
  KytosApp.swift                  # @main, window/tab management, commands
  Models.swift                    # KytosSession, KytosWorkspace, KytosAppModel
  KytosSettings.swift             # Kytos-specific UI preferences
  KytosSettingsView.swift         # Settings window
  KytosPanelViews.swift           # Inspector panels
  Splits/                         # Split tree model + recursive split views
  Terminal/
    KytosTerminalView.swift       # LocalProcessTerminalView subclass, key/mouse/font/search
    KytosTerminalRepresentable.swift  # SwiftUI bridge, delegate, color theming
Sources/KytosWidget/              # macOS widget extension + shared widget snapshot model
Sources/KytosTests/               # Unit tests
Kytos.icon/                       # macOS .icon package compiled by actool
```

### Key Patterns

- **`KytosTerminalView`** — `LocalProcessTerminalView` subclass. Handles key interception, drag-and-drop, font scaling, focus management, search, and shell process lifecycle. Registers a custom OSC 9 handler for progress reporting.
- **`KytosTerminalRepresentable`** — `NSViewRepresentable` bridging `KytosTerminalView` into SwiftUI. Coordinator implements `LocalProcessTerminalViewDelegate` for title/PWD notifications.
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

### Shell Integration

Kytos provides shell integration scripts for bash, zsh, and fish that emit standard OSC escape sequences:

- **OSC 7** — Reports the working directory to the terminal (drives toolbar subtitle and navigator pane labels)
- **OSC 133** — Marks prompt/command zones (semantic prompt marking)
- **OSC 2** — Sets the terminal title (drives window/tab titles)
- **OSC 9;4** — Reports command progress (drives the progress bar overlay)

For zsh, integration is auto-injected via `ZDOTDIR`. For bash and fish, source the appropriate script from your shell config:

```bash
# bash (~/.bashrc)
[ -n "$KYTOS_SHELL_INTEGRATION_DIR" ] && source "$KYTOS_SHELL_INTEGRATION_DIR/bash/kytos.bash"

# fish (~/.config/fish/config.fish)
[ -n "$KYTOS_SHELL_INTEGRATION_DIR" ] && source "$KYTOS_SHELL_INTEGRATION_DIR/fish/vendor_conf.d/kytos-shell-integration.fish"
```

Shell integration scripts are bundled in the app at `Kytos.app/Contents/Resources/kytos/shell-integration/`.

### Build Pipeline

1. **XcodeGen** — `project.yml` defines targets, dependencies, and build settings. Generates `Kytos.xcodeproj` (git-ignored).
2. **SPM Resolution** — SwiftTerm is fetched as a Swift Package dependency (from `https://github.com/migueldeicaza/SwiftTerm.git`, version 1.11.0+).
3. **xcodebuild** — Compiles Swift 6 sources, links SwiftTerm + Carbon + KelyphosKit, produces `Kytos.app`.
