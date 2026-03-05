# Kytos

A terminal emulator for macOS and iPadOS built on [KelyphosKit](../kelyphos) and [SwiftTerm](Submodules/SwiftTerm).

## Building

The Xcode project is generated from `project.yml` using [XcodeGen](https://github.com/yonaskolb/XcodeGen), which is bundled as a Swift Package Manager dependency.

After adding or removing source files, regenerate the project with:

```bash
swift run --package-path .build/checkouts/XcodeGen xcodegen generate --spec project.yml
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

## Session lifecycle (macOS)

| Event | Action |
|---|---|
| App launch | `KytosAppModel.load()` decodes persisted trees, then `reconcileSessionsOnLaunch()` checks each `paneSessionID` against `pane list`. Dead IDs are cleared so the view creates a fresh session. |
| Terminal appears | `PaneWorkspaceTerminalView` creates a pane session if `paneSessionID == nil`; stores the ID back. |
| Pane closed | `pane destroy <id>` called; leaf removed from tree. |
| Window/tab closed | Stream disconnects; session survives in server. |
| App quit | Streams disconnected; server keeps running; sessions survive restart. |
| Server crash | All IDs cleared on next launch; fresh sessions created. |

## iPadOS

No pane server. All terminal sessions use an in-process PTY with the bundled mksh binary. No session persistence between launches.


## Pane — what it provides

[Pane](Submodules/Pane) is a tmux-like terminal multiplexer built on top of SwiftTerm. It exposes a Unix-domain-socket client/server protocol with the following CLI commands:

| Command | Description |
|---|---|
| `pane` | Create a session and attach immediately (default) |
| `pane server` | Start the background server explicitly |
| `pane status` | Check whether a server is running (PID, socket, uptime) |
| `pane list-servers` | Enumerate all live pane servers in the runtime directory |
| `pane create [name] [cmd…]` | Create a named session, optionally running a specific command |
| `pane list` | List all sessions (id, pid, name, state, created time) |
| `pane attach [session-id]` | Attach to a session and stream its terminal (auto-starts server) |
| `pane destroy <session-id>` | Destroy a session |

### Protocol detail

- **Transport**: Unix domain socket (`AF_UNIX / SOCK_STREAM`), one socket per server, path under `$XDG_RUNTIME_DIR` or equivalent.
- **Wire format**: JSON for control messages (`createSession`, `listSessions`, `destroySession`, `ping`); custom binary format for high-frequency terminal data (`snapshot`, `delta`, `input`, `resize`) to minimise overhead.
- **Session model**: sessions are independent PTY processes managed by the server; clients attach and receive a full terminal snapshot on connect, then incremental deltas. Multiple clients can subscribe to the same session simultaneously.
- **Auto-start**: the client auto-starts the server process if the socket is absent or the connection is refused.

### ⚠️ Pane is an executable, not a library

The `pane` package only exposes an executable target — its types are not `public` and cannot be imported. `KytosPaneClient.swift` implements the same Unix-socket / JSON-framing protocol directly, without importing the pane module. The pane binary is bundled in the macOS app via the **Bundle pane** post-build script in `project.yml` and started on-demand by `KytosPaneClient.startServer()`.
