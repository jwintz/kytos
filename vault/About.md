---
title: About Kytos
description: Background and motivation for the Kytos terminal emulator
icon: i-lucide-info
order: 99
navigation:
  title: About
  icon: i-lucide-info
  order: 99
---

Kytos (κύτος — Greek for hollow vessel) is a terminal emulator for macOS that combines Ghostty's world-class rendering engine with an IDE-quality shell built on KelyphosKit.

## Motivation

Terminal emulators on macOS increasingly look like they belong in a browser. Kytos takes a different approach: a native macOS application with real NSToolbar, inspector panels, and a desktop widget — powered by the same rendering engine as Ghostty.

The goal is a terminal that:

1. **Renders perfectly** — libghostty handles all terminal emulation, Metal rendering, and PTY management
2. **Looks native** — KelyphosKit provides NSToolbar, panels, and Liquid Glass vibrancy
3. **Integrates deeply** — shell integration via OSC sequences drives toolbar titles and navigator labels live
4. **Persists reliably** — workspace state, split trees, and tab groups survive relaunches

## Architecture

Kytos is thin by design. It delegates terminal emulation entirely to libghostty and panel chrome entirely to KelyphosKit. The app's own code handles the bridge between them:

- `KytosGhosttyApp` — wraps `ghostty_app_t`, owns C callbacks and the app tick loop
- `KytosGhosttyView` — `NSView` subclass wrapping `ghostty_surface_t`, handles Metal layer and input
- `KytosWorkspace` — `@Observable` split tree model for one window
- `KytosAppModel` — manages window-to-workspace mapping, persistence, and tab restoration

## Credits

Kytos is built on:

- [Ghostty](https://github.com/ghostty-org/ghostty) by Mitchell Hashimoto and contributors
- [KelyphosKit](../kelyphos) for the shell chrome
- SwiftUI and AppKit for the application layer
