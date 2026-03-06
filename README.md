# Kytos

A terminal emulator for macOS and iPadOS built on [KelyphosKit](../kelyphos) and [SwiftTerm](Submodules/SwiftTerm) leveraging [Pane](Submodules/Pane).

## Building

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen), which is bundled as a Swift Package Manager dependency.

After adding or removing source files, regenerate the project with:

```bash
swift run --package-path .build/checkouts/XcodeGen xcodegen generate --spec project.yml
```

Then build:

```bash
xcodebuild -project Kytos.xcodeproj -scheme Kytos-macOS -configuration Debug build
```

Then run:

```bash
$(xcodebuild -project /Users/jwintz/Syntropment/kytos/Kytos.xcodeproj -scheme Kytos-macOS -configuration Debug -showBuildSettings 2>/dev/null | awk '/BUILT_PRODUCTS_DIR/{print $3}' | head -1)/Kytos.app/Contents/MacOS/Kytos
```

## Architecture

| Component | Role |
|---|---|
| **KelyphosKit** | Shell UI — navigator, inspector, utility panels, tab management, keybindings |
| **SwiftTerm** | Terminal emulation (VT100/xterm), PTY rendering |
| **mksh** | Bundled shell binary; default shell on iPadOS, option on macOS |
| **Pane** | Background PTY server (macOS); `KytosPaneClient` connects over Unix socket |

## Split-pane layout

`PaneLayoutTree` (`Models.swift`) is a binary tree where each leaf is a terminal session and each branch is a horizontal/vertical split. On macOS, each terminal leaf stores a `paneSessionID` referencing a live pane server session. On iPadOS, the PTY runs in-process with mksh.

### One pane session per terminal pane

Each leaf in the split tree maps to exactly one pane server session. A pane session is a single PTY process (e.g. a `/bin/zsh` instance) managed by the background server. When you split a terminal, Kytos creates a new pane session for the new pane. This is the expected model — unlike tmux where a "session" groups multiple windows and panes, a pane session is a 1:1 mapping to a single terminal.

The navigator sidebar lists every leaf pane with its shell name (e.g. "zsh") and pane session ID. Multiple panes in the same tab are independent sessions running independent shell processes.

## Session lifecycle (macOS)

| Event | Action |
|---|---|
| App launch | `KytosAppModel.load()` decodes persisted trees, then `reconcileSessionsOnLaunch()` checks each `paneSessionID` against `pane list`. Dead IDs are cleared so the view creates a fresh session. |
| Terminal appears | `PaneWorkspaceTerminalView` creates a pane session if `paneSessionID == nil`; stores the ID back. |
| Pane closed | `pane destroy <id>` called; leaf removed from tree. |
| Window/tab closed | Stream disconnects; session survives in server. |
| App quit | Streams disconnected; server keeps running; sessions survive restart. |
| Server crash | All IDs cleared on next launch; fresh sessions created. |

## Pane

A terminal multiplexer for macOS written in Swift. It is similar in spirit to tmux or screen, allowing you to run terminal sessions in the background and attach/detach from them at will.

### Core Architecture

* **Client-Server Model**: Pane operates with a persistent background server (`PaneServer`) that manages multiple terminal sessions. Clients (`PaneClient`) interact with the server via Unix Domain Sockets located in `/tmp/pane-<uid>/`.
* **Terminal Emulation**: The server uses the **SwiftTerm** library to emulate a full terminal for each session. It connects to local shell processes (like zsh)        using a PTY.
* **Hybrid Communication Protocol**:
  * **JSON**: Used for control commands (creating, listing, or destroying sessions).
  * **Custom Binary Protocol**: A high-performance binary format (`PaneBinaryCodable`) is used for streaming terminal updates. It sends "deltas" (only the
changed lines) to minimize latency and bandwidth.
* **Rendering**: The client uses drivers adapted from **TermKit** (specifically `UnixDriver`) to render the remote terminal state onto the user's local console.

### Key Features

1. **Session Persistence**: Sessions continue running on the server even after you detach or close your terminal window.
2. **Efficient Streaming**: Uses incremental updates (deltas) and a binary wire format to ensure the terminal feels responsive even over the socket connection.
3. **Command Mode (`Ctrl-B`)**: Similar to `tmux`, Pane uses a prefix key (`Ctrl-B`) to trigger commands while attached:
   * `d`: **Detach** from the session.
   * `c`: **Create** a new session and immediately switch to it.
   * `n`: Switch to the **next** session.
   * `p`: Switch to the **previous** session.
4. **Multi-Client Support**: Multiple clients can attach to the same session simultaneously, with the server broadcasting updates to all of them in real-time.
5. **Auto-Lifecycle Management**: The client can automatically launch the server if it isn't already running when you try to create or attach to a session.
6. **Advanced Terminal Support**: Supports 256-color and TrueColor (24-bit) output, bold, dim, blink, invert, and underline styles.

### CLI Interface

The `pane` executable provides several subcommands:
* `pane create [name] [command]`: Starts a new session (optionally with a custom name and command).
* `pane list`: Displays all active sessions, their PIDs, and their status.
* `pane attach [sessionID]`: Connects your current terminal to a background session.
* `pane destroy [sessionID]`: Forcefully terminates a session.
* `pane status`: Reports the health and PID of the running server.
* `pane server`: Manually starts the background server process.
* `pane list-servers`: Lists all active Pane servers detected in the temporary runtime directory.

### Technical Implementation Details

* **Runtime Directory**: `/tmp/pane-<uid>/` contains the communication socket (`default`) and a PID file (`pane.pid`).
* **Concurrency**: Uses Swift Concurrency and `DispatchQueue` extensively to handle asynchronous I/O and process management safely.
* **Platform Support**: While defined for macOS 13+, the inclusion of `WindowsDriver.swift` and `CursesDriver.swift` points towards a highly modular design capable of cross-platform expansion.

### ⚠️ Pane is an executable, not a library

The `pane` package only exposes an executable target — its types are not `public` and cannot be imported. `KytosPaneClient.swift` implements the same Unix-socket / JSON-framing protocol directly, without importing the pane module. The pane binary is bundled in the macOS app via the **Bundle pane** post-build script in `project.yml` and started on-demand by `KytosPaneClient.startServer()`.

### iPadOS

No pane server. All terminal sessions use an in-process PTY with the bundled mksh binary. No session persistence between launches.
