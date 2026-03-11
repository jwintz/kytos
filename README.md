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
| `test` | Run unit tests |
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
  Ghostty/
    KytosGhosttyApp.swift         # ghostty_app_t wrapper, C callbacks
    KytosGhosttyView.swift        # ghostty_surface_t NSView, keyboard/mouse/IME
    KytosTerminalRepresentable.swift  # SwiftUI bridge (NSViewRepresentable)
Sources/KytosWidget/              # macOS widget extension
Sources/KytosTests/               # Unit tests
```

### Key Patterns

- **`KytosGhosttyApp`** — `@Observable @MainActor` singleton wrapping `ghostty_app_t`. Owns config, runtime C callbacks (wakeup, action, clipboard, close), and the app tick loop.
- **`KytosGhosttyView`** — `NSView` subclass wrapping `ghostty_surface_t`. Handles Metal layer, keyboard/mouse forwarding, and IME via `NSTextInputClient`.
- **`KytosTerminalRepresentable`** — Thin `NSViewRepresentable` bridging `KytosGhosttyView` into SwiftUI.
- **`KytosWorkspace`** — `@Observable` model holding a single `KytosSession` per window/tab.
- **`KytosAppModel`** — Manages window-to-workspace mapping, persistence, and tab group restoration using native macOS window tabs.

### Build Pipeline

1. **GhosttyKit** — Built from Ghostty source via `zig build` (arm64, ReleaseFast). Produces `Frameworks/GhosttyKit.xcframework` (static library, git-ignored).
2. **XcodeGen** — `project.yml` defines targets, dependencies, and build settings. Generates `Kytos.xcodeproj` (git-ignored).
3. **xcodebuild** — Compiles Swift 6 sources, links GhosttyKit + Carbon + KelyphosKit, produces `Kytos.app`.

