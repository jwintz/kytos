---
title: Kytos
description: A terminal emulator for macOS built on libghostty and KelyphosKit
navigation: false
---

::u-page-hero
---
title: Kytos
description: A terminal emulator for macOS built on libghostty and KelyphosKit. Ghostty's rendering engine inside an IDE-quality shell — navigator, inspector, utility panels, and a desktop widget.
links:
  - label: Get Started
    to: /guide/installation
    icon: i-lucide-arrow-right
    color: neutral
    size: xl
  - label: View on GitHub
    to: https://github.com/jwintz/kytos
    icon: simple-icons-github
    color: neutral
    variant: outline
    size: xl
---
::

::u-page-grid{class="lg:grid-cols-3 max-w-(--ui-container) mx-auto px-4 pb-24"}

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /architecture/ghostty
icon: i-lucide-terminal
---
#title
Ghostty Engine

#description
libghostty handles terminal emulation, Metal rendering, PTY management, and splits. All terminal settings via `~/.config/ghostty/config`.
:::

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /architecture/overview
icon: i-lucide-layout-panel-left
---
#title
KelyphosKit Shell

#description
Navigator, inspector, and utility panels powered by KelyphosKit. The shell adapts to macOS conventions with NSToolbar and native window management.
:::

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /architecture/sessions
icon: i-lucide-layers
---
#title
Sessions & Workspaces

#description
Multiple windows. Multiple tabs. Split panes. Workspace state persists across relaunches with robust UUID-based tab restoration.
:::

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /architecture/shell-integration
icon: i-lucide-plug
---
#title
Shell Integration

#description
OSC escape sequences for live process title and working directory updates. Drives toolbar title, subtitle, and navigator pane labels dynamically.
:::

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /architecture/widget
icon: i-lucide-layout-grid
---
#title
Desktop Widget

#description
A macOS widget extension showing workspace activity. Snapshot written directly into the widget's container for reliable cross-process updates.
:::

:::u-page-card
---
spotlight: true
class: col-span-3 lg:col-span-1
to: /development/building
icon: i-lucide-wrench
---
#title
Reproducible Builds

#description
All build operations via `pixi run`. GhosttyKit from source, XcodeGen project, full distribution pipeline — sign, DMG, notarize.
:::

::
