---
title: Changelog
description: Release history and notable changes to Kytos
navigation:
  icon: i-lucide-history
  order: 98
order: 98
tags:
  - changelog
  - releases
---

All notable changes to Kytos are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

:changelog-versions{:versions='[{"title":"Unreleased","description":"Initial revision"}]'}

---

## Unreleased

### Added

- Initial release of Kytos terminal emulator
- libghostty integration — terminal emulation, Metal rendering, PTY management, splits
- KelyphosKit shell — navigator, inspector, utility panels, NSToolbar
- `KytosGhosttyApp` — `ghostty_app_t` wrapper with C callback system and app tick loop
- `KytosGhosttyView` — `NSView` wrapping `ghostty_surface_t` with Metal layer and NSTextInputClient
- `KytosTerminalRepresentable` — SwiftUI bridge for `KytosGhosttyView`
- `KytosWorkspace` — `@Observable` split tree model per window
- `KytosAppModel` — window-to-workspace mapping, persistence, widget snapshots
- Tab restoration with retry loop — groups windows correctly after relaunch
- UUID remapping for restored windows (`restoredWindowIDRemap`)
- Shell integration — OSC 0/2 (process title) and OSC 7 (working directory) support
- Dynamic toolbar title and subtitle from shell integration signals
- macOS widget extension with JSON snapshot written to widget container
- Ghostty resource detection via `terminfo/78/xterm-ghostty` sentinel
- Shell integration scripts copied to `Contents/Resources/ghostty/shell-integration/`
- Settings window with "Open Ghostty Config" shortcut
- Full distribution pipeline: `build-release` → `sign` → `dmg` → `notarize`
- `pixi run` task system for all build operations
