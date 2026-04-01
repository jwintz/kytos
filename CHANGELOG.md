# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Replace libghostty/GhosttyKit backend with SwiftTerm (SPM, upstream v1.13.0+)
- Terminal view is now `KytosTerminalView` (`LocalProcessTerminalView` subclass) in `Terminal/`
- SwiftUI bridge is now `KytosTerminalRepresentable` with `LocalProcessTerminalViewDelegate` Coordinator
- Terminal appearance managed via `KytosTerminalPalette` with itermcolors support (nano + default schemes)
- Shell integration scripts rewritten for kytos (bash, zsh, fish) emitting OSC 7/133/2/9;4
- Build system simplified: no zig/gettext dependencies, no GhosttyKit build step
- Settings view no longer references Ghostty configuration
- Terminal background is now translucent (clear background, non-opaque layer)
- Default font changed to SF Mono 11pt (was 13pt)
- Toolbar title uses OSC terminal title as immediate fallback when process name is not yet available

### Added

- OSC 9;4 progress report handler via SwiftTerm parser hook
- Kytos shell integration scripts with auto-injection for zsh via ZDOTDIR
- `KYTOS_SHELL_INTEGRATION_DIR` environment variable set in spawned shells
- `ITermColorsParser` for loading `.itermcolors` theme files
- `KytosTerminalPalette` with light/dark variants, scheme selection (Default, Nano), custom theme loading from `~/.config/kytos/`
- Font family and size settings (Settings > Terminal > Font), persisted via UserDefaults
- Color scheme chooser in settings (Default, Nano)
- Keyboard shortcuts for split management: Cmd+D (horizontal), Cmd+Shift+D (vertical)
- Keyboard shortcuts for split navigation: Ctrl+Cmd+[/] (prev/next), Option+Cmd+arrows (spatial)
- Keyboard shortcut Cmd+T for new tab, Cmd+Shift+Return for equalize splits
- Bundled nano-dark.itermcolors and nano-light.itermcolors theme files
- Cursor shape setting (Bar, Block, Underline) in Settings > Terminal > Font, defaults to Bar

### Fixed

- Convert OSC 7 file:// URL to plain path for CWD subtitle display and process tree matching
- Strip numericPad/function modifier flags for reliable arrow key shortcut matching
- Font and cursor shape changes in settings now propagate immediately to all existing terminal panes
- Cursor no longer stays hollow after window refocus (observe didBecomeKeyNotification)

### Removed

- GhosttyKit.xcframework dependency and `Ghostty/` source directory
- Ghostty shell integration scripts, terminfo, and sentinel file
- `build-ghostty` and `ensure-ghostty` pixi tasks
- zig and gettext conda dependencies
- "Open Ghostty Config" settings panel
- "Reload Ghostty Config" keybinding
