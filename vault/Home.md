---
title: Kytos
description: A terminal emulator for macOS built on libghostty and KelyphosKit
icon: i-lucide-terminal
order: 0
navigation:
  title: Home
  icon: i-lucide-home
  order: 0
---

Kytos is a terminal emulator for macOS built on [libghostty](https://github.com/ghostty-org/ghostty) and [KelyphosKit](../kelyphos). Ghostty's rendering engine inside an IDE-quality shell — navigator, inspector, utility panels, and a desktop widget.

## Quick Start

```bash
pixi run build    # Build GhosttyKit + generate Xcode project + compile
pixi run run      # Build if needed + launch Kytos.app
```

## Requirements

- macOS 26+ (Tahoe)
- [pixi](https://pixi.sh) package manager
- Xcode with macOS 26 SDK
- Ghostty source at `~/Syntropment/ghostty`

## Configuration

Terminal settings are managed via Ghostty's config file:

```
~/.config/ghostty/config
```

## Documentation

- [[1.guide/1.installation|Installation]]
- [[1.guide/2.usage|Usage]]
- [[1.guide/3.configuration|Configuration]]
- [[2.architecture/1.overview|Architecture Overview]]
- [[2.architecture/2.ghostty|Ghostty Integration]]
- [[2.architecture/3.sessions|Sessions & Workspaces]]
- [[2.architecture/4.shell-integration|Shell Integration]]
- [[3.development/1.building|Building from Source]]
- [[3.development/2.distribution|Distribution & Notarization]]
- [[Changelog]]
