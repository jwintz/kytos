# iPadOS Terminal Support via ios_system

## Context

Kytos has a fully functional macOS terminal backed by the Pane daemon (socket-based multiplexer). On iOS, the target exists in `project.yml` but the terminal is inert — there's a stub `MacOSLocalProcessTerminalCoordinator` at `KytosApp.swift:477` that does nothing. The goal is to make Kytos a functional iPadOS terminal using holzschu's **ios_system** ecosystem (drop-in `system()` replacement with thread-local I/O) instead of the Pane daemon, which is macOS-only.

### Key decisions

- **Keep jwintz/SwiftTerm** (don't switch to holzschu fork). The holzschu fork adds only minor iOS clipboard fixes (~340 lines across 5 files). It does NOT add an ios_system coordinator. a-Shell itself uses a WebView (hterm.js), not SwiftTerm. Cherry-pick useful fixes if needed.
- **Drop mksh** entirely (both platforms). macOS uses Pane daemon which runs the user's shell directly. iOS will use ios_system's default shell (dash).
- **App group**: `group.me.jwintz.Syntropment` (shared between Kytos and Hyalo).
- **Home directory**: `<app-group-container>/home/` with standard subdirectories.

---

## Phase 1: Submodules & Build System

**Goal**: Get ios_system compiling into Kytos-iOS target, remove mksh.

### 1.1 Remove mksh submodule
- `git submodule deinit Submodules/mksh && git rm Submodules/mksh`
- Remove `Build mksh` post-build script from Kytos-macOS in `project.yml`
- Remove `Build mksh for iOS` post-build script from Kytos-iOS in `project.yml`

### 1.2 Add ios_system + network_ios as SPM packages

**`project.yml`** — add to `packages:` section:
```yaml
ios_system:
  url: https://github.com/holzschu/ios_system.git
  from: 3.0.4
network_ios:
  url: https://github.com/holzschu/network_ios.git
  from: 0.2
```

Add to Kytos-iOS target dependencies: `ios_system`, `shell`, `files`, `text`, `network_ios`.

**`Package.swift`** — mirror dependencies for XcodeGen resolution.

### 1.3 Update KytosSettings.swift

- Replace `ShellChoice.embeddedMksh` with `ShellChoice.dash` on iOS
- `resolvedCommandLine()` → return `["dash"]` on iOS (ios_system's built-in POSIX shell)
- macOS: change default to `.systemShell` (Pane daemon runs user's shell, mksh no longer bundled)

**Files**: `project.yml`, `Package.swift`, `.gitmodules`, `KytosSettings.swift`

---

## Phase 2: iOS Terminal Coordinator

**Goal**: Create `KytosIOSSystemCoordinator` bridging ios_system I/O ↔ SwiftTerm.

### Architecture
```
User types → send(source:data:) → write to stdin pipe
                                      ↓
                               ios_system reads thread_stdin
                               ios_system writes thread_stdout
                                      ↓
                               read from stdout pipe → feed(byteArray:) → TerminalView
```

### 2.1 Create `Sources/KytosApp/KytosIOSSystemCoordinator.swift`

`#if os(iOS)` only. Implements `TerminalViewDelegate`:

- **Properties**: stdin/stdout pipe file descriptors, shell thread, cols/rows
- **`start()`**: Creates POSIX pipe pairs, calls `initializeEnvironment()`, sets `$HOME`/`$PATH`/`$TERM`/`$COLUMNS`/`$LINES`, sets `thread_stdout`/`thread_stdin` via `ios_setStreams()`, starts shell loop on background thread, starts read loop for stdout pipe
- **`send(source:data:)`**: Write user keystrokes to stdin pipe write-end
- **`sizeChanged(source:newCols:newRows:)`**: Update `$COLUMNS`/`$LINES` env vars (ios_system has no SIGWINCH). Store cols/rows for future sessions.
- **`disconnect()`**: Close pipes, signal shell thread to exit
- **Shell loop**: Call `ios_system("dash")` on background thread
- **Read loop**: Read stdout pipe read-end, dispatch `tv.feed(byteArray:)` on main queue

### 2.2 Replace iOS stub in KytosApp.swift

- Replace the empty `MacOSLocalProcessTerminalCoordinator` stub at line 477 with usage of `KytosIOSSystemCoordinator`
- In `KytosTerminalManager.getOrCreateTerminal()` iOS branch, instantiate and start the coordinator

**Files**: New `KytosIOSSystemCoordinator.swift`, modify `KytosApp.swift`

---

## Phase 3: Home Directory & App Group

**Goal**: Set up writable filesystem and sharing with Hyalo.

### 3.1 Change app group identifier

| File | Change |
|------|--------|
| `Kytos-iOS.entitlements` | `group.me.jwintz.Kytos` → `group.me.jwintz.Syntropment` |
| `KytosWidget-iOS.entitlements` | same |
| `KytosWidgetSnapshot.swift` | Update `appGroupID` constant |

Add migration: copy existing data from old container on first launch.

### 3.2 Create filesystem helper

```swift
func setupHomeDirectory() -> String {
    let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.me.jwintz.Syntropment")!
    let home = container.appendingPathComponent("home")
    for dir in ["Documents", "Library", "Library/bin", "tmp", ".config"] {
        try? FileManager.default.createDirectory(
            at: home.appendingPathComponent(dir), withIntermediateDirectories: true)
    }
    return home.path
}
```

`$HOME` → `<container>/home/`, `$PATH` includes `~/Library/bin:~/Documents/bin`.

### 3.3 Hyalo side (deferred)

Add `group.me.jwintz.Syntropment` to Hyalo's iOS entitlements when ready. Both apps then share the same container.

**Files**: `Kytos-iOS.entitlements`, `KytosWidget-iOS.entitlements`, `KytosWidgetSnapshot.swift`, new `KytosIOSFilesystem.swift`

---

## Phase 4: Ungate Cross-Platform UI

**Goal**: Make split panes, layout tree, and sessions work on iOS.

### 4.1 Models.swift — ungate PaneLayoutTree methods

Move these out of `#if os(macOS)` (line 134-235):
- `find(id:)`, `firstLeafID()`, `allTerminalLeaves()`, `leafCount`
- Keep Pane-specific methods macOS-only: `allPaneSessionIDs()`, `clearingDeadSessions()`

### 4.2 PaneLayoutTreeView — make cross-platform

- Replace `NSColor.separatorColor` → `Color.separator`
- Wrap `NSCursor` calls in `#if os(macOS)`
- Split pane layout, drag gestures, and ratio persistence are already SwiftUI

### 4.3 PaneWorkspaceTerminalView iOS branch

- Already creates terminal with `paneSessionID: nil` (correct for ios_system)
- Add stream-failed overlay support for iOS

**Files**: `Models.swift`, `KytosApp.swift` (PaneLayoutTreeView, PaneWorkspaceView)

---

## Phase 5: a-Shell Package Compatibility (deferred)

**Goal**: Run a-Shell's wasm-compiled packages.

- Add WasmKit (or wasm3) as SPM dependency
- Implement `pkg` command as ios_system extra command
- Download wasm binaries from a-Shell's package repository to `~/Library/bin/`
- Register wasm binary execution hook via `addCommandList()`

---

## Phase 6: libgit2 Integration (deferred)

**Goal**: Provide `git` CLI on iOS.

- Add holzschu/libgit2 fork as submodule, build as xcframework
- Wrap as ios_system command (rename `main()` → `git_main()`)
- Register in `extraCommandsDictionary.plist`
- Feasible but non-trivial; defer until terminal is stable

---

## Risks

| Risk | Mitigation |
|------|-----------|
| ios_system I/O bypasses `FILE*` pipes (raw fd writes) | Use `dup2()` on actual file descriptors, not just `FILE*` streams |
| No SIGWINCH for TUI apps (no fork/exec on iOS) | Set `$COLUMNS`/`$LINES`; TUI apps like less/vi read these |
| Binary size from ios_system frameworks | Include only essential frameworks (ios_system, shell, files) initially |
| App group migration loses existing widget data | One-time migration on first launch |

---

## Verification

1. Build Kytos-iOS target (simulator)
2. Launch on iPad simulator → dash shell prompt appears
3. Run basic commands: `ls`, `pwd`, `cd`, `echo`, `cat`
4. Run `curl` for network commands
5. Verify `$HOME` points to app group container
6. Verify widget still reads snapshot data
7. Split pane works on iPadOS
