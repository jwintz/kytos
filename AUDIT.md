# Kytos UX Audit & Implementation Plan

## Implementation Status

The following table reflects work completed in the first implementation session. Findings marked ✅ are resolved; ⏳ are deferred to a future session.

| ID | Finding | Status | Notes |
|----|---------|--------|-------|
| A1 | Hardcoded 800×600 frame phantom resize | ✅ Fixed | `TerminalView(frame: .zero)` |
| A2 | Forced −1 col redraw hack | ✅ Fixed | Single `sendBinaryResize(cols, rows)` after snapshot feed |
| A3 | NotificationCenter observer leak | ✅ Fixed | `Coordinator` class holds and removes token in `deinit` |
| A4 | `updateNSView` unconditional appearance re-apply | ✅ Fixed | Settings hash guard in `Coordinator.lastSettingsHash` |
| A5 | Resize during initial attach discarded | ✅ Fixed | `pendingResizeDuringAttach` buffers and flushes in `finishAttach` |
| B1 | Snapshot `ESC[2J` flash | ✅ Fixed | Per-row `ESC[row;1H` absolute positioning, no clear |
| B2 | Cell-by-cell SGR reset causes banding | ✅ Fixed | SGR emitted only when `cell.attribute` changes |
| B3 | `defaultInvertedColor` falls through to default | ✅ Fixed | Emits SGR `7` (reverse video) when inverse style bit not set |
| B4 | Cursor flash during delta outside cursor row | ✅ Fixed | `ESC[s]` / `ESC[u]` save/restore around delta row writes |
| B5 | Wide character / CJK spacer cells misalign | ✅ Fixed | Spacer cells (`cell.width == 0`) skipped |
| B6 | Short delta lines leave stale characters | ✅ Fixed | `ESC[K]` erase-to-EOL appended after each short row |
| C1 | `loadITermColors` called twice | ✅ Fixed | Direct call removed from `getOrCreateTerminal` |
| C2 | `nativeBackgroundColor` reset on every refresh | ℹ️ Noted | No user-visible impact; left as-is |
| C3 | Cursor blink not wired | ✅ Fixed | Blink combined with cursor style → `.blinking*` variants |
| C4 | `ansi256PaletteStrategy` not exposed | ✅ Fixed | Setting added; picker in Settings → Terminal; auto-selects `.base16Lab` when `.itermcolors` palette is loaded |
| D1 | 50-message loop limit in snapshot acquisition | ✅ Fixed | 500-message budget loop |
| D2 | Silent failure on missing snapshot | ✅ Fixed | "Stream failed" overlay with Retry button |
| D3 | App quit blocks on `readLoop` poll | ℹ️ Noted | Existing known issue; 500 ms max delay, acceptable |
| D4 | Navigator process names not live | ✅ Fixed | `foregroundProcessName(for:)` in `KytosTerminalManager`; 1s polling in `KytosSessionsSidebar`; `PaneLeafRow` shows foreground process as primary label |
| D5 | Scrollback not restored from snapshots | ✅ Fixed | New `0004-scrollback-in-snapshots.patch`; server sends up to 500 scrollback lines; client feeds them as plain output before the screen so SwiftTerm's scrollback ring is populated on reattach |

### Session 3 — Stability & UX Fixes (2026-03-06)

| ID | Finding | Status | Notes |
|----|---------|--------|-------|
| E1 | `NSGenericException` constraint loop on launch | ✅ Fixed | `.containerRelativeFrame(.vertical)` inside `NavigationSplitView` detail column created height feedback loop; replaced with `.frame(maxWidth: .infinity, maxHeight: .infinity)` |
| E2 | SIGTERM signal handler called AppKit (unsafe) | ✅ Fixed | `disconnectAll()` + `save()` wrapped in `DispatchQueue.main.async` |
| E3 | ⌘0 conflicted with Kelyphos shortcut | ✅ Fixed | Reset font size moved to ⌘R (keycode 15) |
| E4 | Submodule URLs not pointing to forks | ✅ Fixed | `.gitmodules` + remotes updated to `https://github.com/jwintz/SwiftTerm.git` and `https://github.com/jwintz/Pane.git` |
| E5 | "Stream failed" overlay not triggered on nil snapshot | ✅ Fixed | `notifyStreamFailed()` added to `handleAttachResponse` guard |
| E6 | Retry button didn't actually reconnect | ✅ Fixed | Retry posts `KytosRetryStream`; coordinator `retry()` calls `startStream` with `lastCols`/`lastRows` directly |
| E7 | Split panes not resizable (window size ratchet) | ✅ Fixed | `HSplitView`/`VSplitView` replaced with custom `PaneSplitLayout: Layout` which returns `proposal.replacingUnspecifiedDimensions()` — no min-size pushback; 5px divider with 11px hit area, proper resize cursor |
| E8 | Split geometry not persisted | ✅ Fixed | Ratio stored in `UserDefaults` keyed by `kytos.split.<leftLeafID>.<rightLeafID>`; restored on `.onAppear`; drag uses `value.location` in named coordinate space for linear tracking |
| E9 | Navigator/inspector panel state not persisted across relaunches | ✅ Fixed | Panel prefix changed from `window.<UUID>` (unstable) to `session.<UUID>` (stable, persisted in model); `KelyphosShellState` re-created in `onAppear` once workspace is available |

### Remaining Work

All audit findings are resolved. No outstanding items from prior sessions.

**Next:** macOS desktop widget (`Kytos-Widget` target) showing live terminal stats.

---

## Context

Kytos is a SwiftUI terminal app wrapping **SwiftTerm** for rendering and **Pane** as the backend PTY multiplexer. The core UX problems fall into four buckets: (1) visual artefacts on resize/redraw, (2) ANSI reconstruction quality, (3) color correctness, and (4) structural issues that cause subtle glitches. The SwiftTerm TerminalApp examples reveal several best-practice patterns Kytos is not following.

---

## Audit Findings

### A — Resize & Redraw (High Impact)

**A1. Hardcoded 800×600 frame triggers phantom resize cycle**
- `getOrCreateTerminal` creates `TerminalView(frame: CGRect(x:0, y:0, width:800, height:600))`
- SwiftTerm fires `sizeChanged` at 800×600, which sends a resize to the pane server before the real layout has happened
- This wastes a SIGWINCH, can cause a flicker, and pollutes the streaming coordinator's `lastCols/lastRows`
- Fix: initialize with `.zero` frame; SwiftTerm handles first layout correctly

**A2. Forced -1 col redraw hack is fragile**
- `finishAttach` sends `(cols-1, rows)` then sleeps 50ms then sends `(cols, rows)` to coerce a SIGWINCH/redraw
- Race: if the socket write or the server is slow, the two resize messages may arrive together or out of order, showing a momentary narrow terminal
- Better approach: after feeding the snapshot, send a single real-size resize; SwiftTerm's `feed()` already positions the cursor correctly from the snapshot ANSI

**A3. NotificationCenter observer leak in `makeNSView`**
- `addObserver(forName: "KytosLayoutChanged" ...)` is called every time `makeNSView` is called (SwiftUI can call this multiple times across pane lifecycle)
- The closure is retained by NotificationCenter indefinitely; over time this stacks duplicate observers that each trigger `needsLayout`
- Fix: use `Coordinator` to hold the token and call `removeObserver` in `deinit`

**A4. `updateNSView` unconditionally re-applies appearance**
- Called on every SwiftUI body refresh (including unrelated state changes)
- Re-sets font, colors, cursor style on every frame — triggers unnecessary redraws inside SwiftTerm
- Fix: cache last-applied settings hash in `Coordinator`; only call `updateTerminalAppearance` when something actually changed

**A5. Initial stream start before layout is settled**
- `startStream` is triggered by the first `sizeChanged`; but if SwiftUI triggers a second layout pass quickly (e.g. sidebar animation), a second `sizeChanged` fires before the server responds
- The `streaming` guard prevents duplicate streams, but the resize message sent mid-attach lands on the server while the subscribe handshake is in flight
- Fix: buffer resize messages that arrive while the initial snapshot is pending; flush them after `finishAttach`

---

### B — ANSI Reconstruction (High Impact)

**B1. Every snapshot starts with `ESC[2J` (clear screen)**
- `toANSIBytes()` opens with `\u{1b}[2J\u{1b}[H` unconditionally
- If there is any lag between the clear and the snapshot bytes being fed to SwiftTerm, the user briefly sees a blank terminal (visible flash on slow machines or heavy CPU load)
- Fix: do NOT clear; instead set absolute cursor positions per row using `ESC[row;colH` to overwrite in-place, or pre-build the entire buffer and feed it atomically

**B2. Cell-by-cell `ESC[0m` reset causes color banding during rapid updates**
- `sgrBytes()` always starts with `"0"` (full reset) before applying each cell's attributes
- During rapid output (e.g. `cat` of a colorful file) this means every attribute change goes reset→restyle, producing visible banding/flash instead of smooth transitions
- Fix: track the running attribute state; emit only the _delta_ SGR codes needed to transition from the previous attribute to the new one

**B3. `defaultInvertedColor` silently falls through to `defaultColor`**
- Both `.defaultColor` and `.defaultInvertedColor` return `"39"` / `"49"` (reset to default)
- Inverse-video cells (e.g. selected text in vim, reverse-mode prompts) appear as plain default color instead of inverted
- Fix: `defaultInvertedColor` should emit SGR `7` (reverse video) and _not_ emit explicit fg/bg codes, or be tracked as a flag that sets `parts.append("7")`

**B4. No cursor position in deltas until the end**
- `toANSIBytes()` for delta places the cursor at `(cursorY+1, cursorX+1)` at the very end
- If the cursor is _inside_ the delta region, SwiftTerm advances it naturally through the written characters and the final positioning is correct; but if the cursor is _outside_ the delta region (e.g. status-bar update below cursor), the cursor visibly jumps during the feed
- Fix: save cursor (`ESC[s`) before feeding delta lines, restore (`ESC[u`) after the last line, then do the final cursor placement

**B5. Wide character (CJK / emoji) cells not handled**
- `cell.char` for a wide character is a multi-codepoint string but the code writes raw UTF-8 bytes without accounting for terminal column advance
- A double-width character occupies 2 columns; if the adjacent cell is a spacer (empty string), writing both cells as-is will misalign everything to the right
- Fix: detect zero-width/double-width cells (check `cell.char.unicodeScalars` width) and skip spacer cells; or emit a space for the second column of a wide char

**B6. Delta does not clear to EOL after short lines**
- `toANSIBytes()` for delta starts each row with `ESC[row;1H ESC[2K` (move + erase line)
- `ESC[2K` erases the whole line including content before the cursor — this is correct and good
- However: the erase is followed by writing only `line.count` cells, which may be shorter than `cols` (e.g. a line that ends mid-screen)
- On subsequent deltas the remainder of the line is correctly cleared, but between two deltas there can be leftover characters from a previous longer line if the server sends a partial line update
- Fix: after writing cells, check if `line.count < cols` and emit `ESC[K` (erase to end-of-line) to clear the tail

---

### C — Color Handling (Medium Impact)

**C1. `loadITermColors` called twice at terminal creation**
- `getOrCreateTerminal` calls `loadITermColors` directly, then `updateTerminalAppearance` calls it again (via `makeNSView` → `updateTerminalAppearance`)
- Net effect: colors are loaded twice on every pane creation; harmless but wasteful and can mask ordering bugs

**C2. Color scheme changes on live terminals**
- `updateTerminalAppearance` is called in `updateNSView/updateUIView` every SwiftUI refresh
- If the system dark/light mode changes while a pane is open, colors update immediately — which is good — but the `nativeBackgroundColor = .clear` line is also re-set needlessly
- No issues in practice, but the code path is not intentional

**C3. Cursor blink not fully wired**
- `KytosSettings.shared.cursorBlink` is stored and exposed in the Settings UI
- `updateTerminalAppearance` reads `settings.cursorStyle` but does NOT apply blink
- The comment says "SwiftTerm's TerminalView doesn't seem to expose a direct blink toggle"; in fact `TerminalView.caretBlink` is a public property on macOS — it should be set here

**C4. `ansi256PaletteStrategy` not exposed**
- SwiftTerm supports `.base16Lab` (perceptually-matched 256-color) vs `.xterm` (standard) strategies
- Kytos never sets this; defaults to `.xterm`
- Nice-to-have: expose as a setting (or default to `.base16Lab` which looks better with custom palettes)

---

### D — Structural / Concurrency (Medium Impact)

**D1. 50-message loop limit in snapshot acquisition**
- `startStream` and `handleAttachResponse` both use `for i in 0..<50 { ... }` to read the initial handshake
- If more than 50 early deltas arrive before the snapshot (unlikely but possible with a very active shell), the loop exits without a snapshot and the terminal stays blank
- Fix: loop until `response != nil && snapshot != nil`, with a message budget as a safety cap (e.g. 500)

**D2. Silent failure when snapshot is missing**
- `guard let snap = snapshot else { return }` — the terminal just stays blank with no user feedback
- Fix: post a notification or update a `@Published` error state that PaneWorkspaceTerminalView can observe, showing a "Reconnecting…" overlay

**D3. App quit hangs due to blocking `readLoop`**
- Already noted in PLAN.md: `readLoop` calls `readFullMessage()` which blocks on `poll()`
- The existing `disconnect()` calls `shutdownSocket()` but the `poll` timeout is 500ms; on quit, each streaming terminal can delay shutdown by up to 500ms
- Already in existing known-issues list; documented here for completeness

**D4. Navigator process names not live**
- Session leaves show "Shell" (from `commandLine?.first`) or the stored command
- The foreground process changes constantly (e.g. `vim`, `git`, `make`) but the navigator never updates
- Fix: periodically poll the process tree from `KytosPanelViews` process info and write the foreground process name back into a `@Published` property that `PaneLeafRow` can observe

**D5. Scrollback not restored from snapshots**
- Pane snapshots only contain the visible screen (`rows` lines); scrollback is not transmitted
- This is a Pane protocol limitation, but Kytos should make it clear: scrollback is intentionally empty on reattach
- Nice-to-have: add a Pane patch that includes a configurable number of scrollback lines in snapshots

---

## Implementation Plan

### Phase 1 — Fix Resize & Redraw Artefacts (P0)

**1a. Initialize TerminalView with `.zero` frame**
- File: `KytosApp.swift`, `getOrCreateTerminal`
- Change: `TerminalView(frame: .zero)` instead of `CGRect(x:0,y:0,width:800,height:600)`
- Benefit: eliminates phantom 800×600 sizeChanged; first real layout gives correct cols/rows

**1b. Remove the -1 col forced-redraw hack**
- File: `KytosPaneStreamingCoordinator.swift`, `finishAttach`
- After `feed(byteArray: bytes)` the terminal is already in the right state from the snapshot
- Replace the `sendBinaryResize(cols-1,rows)` + sleep + `sendBinaryResize(cols,rows)` with a single `sendBinaryResize(cols, rows)` to ensure the server knows the real size, then let the shell redraw naturally via SIGWINCH from the server
- If the server does not SIGWINCH on attach, add a Pane patch (or the existing `0001` patch handles this)

**1c. Fix NotificationCenter observer leak**
- File: `KytosApp.swift`, `PaneWorkspaceTerminalRepresentable`
- Add `makeCoordinator()` return a proper `Coordinator` class that holds `var layoutObserver: NSObjectProtocol?`
- In `makeNSView`, store the token in `context.coordinator.layoutObserver`; coordinator `deinit` calls `NotificationCenter.default.removeObserver(layoutObserver!)`

**1d. Guard `updateNSView/updateUIView` with a settings hash**
- File: `KytosApp.swift`, `PaneWorkspaceTerminalRepresentable`
- Add `@State private var lastAppliedSettingsHash: Int = 0` (or put in Coordinator)
- Compute a hash of `(fontFamily, fontSize, cursorStyle, cursorBlink, colorScheme)` in `updateNSView`; only call `updateTerminalAppearance` when it changes

---

### Phase 2 — Fix ANSI Reconstruction (P0)

**2a. Remove `ESC[2J` clear from snapshot rendering**
- File: `KytosPaneClient.swift`, `toANSIBytes()` on `KytosPaneTerminalSnapshot`
- Replace the leading clear-screen with: for each row, emit `ESC[row;1H` then write cells
- This writes content in-place without a blank flash; SwiftTerm accumulates the full screen state before painting

**2b. SGR delta encoding — emit only changed attributes**
- File: `KytosPaneClient.swift`, `sgrBytes()` and both `toANSIBytes()` implementations
- Track `currentAttr: KytosPaneCellAttribute?` across cells in the row loop
- Only emit `ESC[0m` + new SGR if `cell.attribute != currentAttr`; skip entirely if equal
- This eliminates the per-cell reset that causes color banding

**2c. Fix `defaultInvertedColor` SGR encoding**
- File: `KytosPaneClient.swift`, `sgrForeground()` / `sgrBackground()`
- When either fg or bg is `.defaultInvertedColor`, add `"7"` (reverse video) to the SGR parts and do NOT emit explicit fg/bg codes for that color
- Alternative: the server could normalize inverse into concrete fg/bg colors — check Pane's `PaneRemoteTerminal` to see if `defaultInvertedColor` is used for anything other than true reverse-video

**2d. Save/restore cursor around delta feeds**
- File: `KytosPaneClient.swift`, `toANSIBytes()` on `KytosPaneTerminalDelta`
- Prepend `ESC[s` (save cursor); at the end emit `ESC[u` then the final `ESC[cursorY+1;cursorX+1H`
- Prevents cursor flash when delta is outside the cursor row

**2e. Handle wide characters (CJK / emoji)**
- File: `KytosPaneClient.swift`, both `toANSIBytes()` implementations
- Add a helper: `func isWideChar(_ s: String) -> Bool` using `s.unicodeScalars.first.flatMap { Unicode.Scalar($0.value) }` and a width lookup (or check if `cell.char.isEmpty` as a spacer indicator)
- Skip cells where `char.isEmpty` and the previous cell was wide; or emit a space

**2f. Erase-to-EOL on short delta lines**
- File: `KytosPaneClient.swift`, `toANSIBytes()` on `KytosPaneTerminalDelta`
- After writing all cells for a row, if `line.count < cols`, emit `ESC[K`

---

### Phase 3 — Color & Settings Polish (P1)

**3a. Wire cursor blink**
- File: `KytosApp.swift`, `updateTerminalAppearance`
- Add: `#if os(macOS) view.caretBlink = settings.cursorBlink #endif`

**3b. Deduplicate `loadITermColors` call**
- File: `KytosApp.swift`, `getOrCreateTerminal`
- Remove the direct `loadITermColors(from:url, into:terminal)` call; rely solely on `updateTerminalAppearance` (called immediately after) to apply colors

**3c. Expose `ansi256PaletteStrategy` as a setting**
- File: `KytosSettings.swift`, `KytosSettingsView.swift`, `KytosApp.swift`
- Add `var ansi256Palette: AnsiPaletteStrategy` (`.xterm` / `.base16Lab`) to `KytosSettings`
- Apply in `updateTerminalAppearance`: `view.terminal.ansi256PaletteStrategy = settings.ansi256Palette`
- Add a picker in Settings → Appearance

---

### Phase 4 — Streaming Robustness (P1)

**4a. Remove arbitrary 50-message limit**
- File: `KytosPaneStreamingCoordinator.swift`, `startStream` and `handleAttachResponse`
- Replace `for i in 0..<50` with `var budget = 500; while budget > 0 { budget -= 1; ... }`
- Keep the early-exit `if response != nil && snapshot != nil { break }`

**4b. Surface snapshot failure to the UI**
- File: `KytosPaneStreamingCoordinator.swift`, after the `guard let snap` check
- Post `NotificationCenter` notification or call back through a new `onStreamError: ((Error) -> Void)?` closure
- File: `KytosApp.swift`, `PaneWorkspaceTerminalView` — show a small "Reconnecting…" overlay when stream setup fails, with a manual retry button

**4c. Buffer resize messages during initial attach**
- File: `KytosPaneStreamingCoordinator.swift`, `sizeChanged`
- Add `var pendingResizeDuringAttach: (cols: Int, rows: Int)?`
- In `sizeChanged`, if `streaming && connection == nil`, store to `pendingResizeDuringAttach`
- In `finishAttach`, after setting `self.connection`, flush the pending resize if present

---

### Phase 5 — Navigator & Process Names (P2)

**5a. Save resolved command line at session creation**
- File: `KytosApp.swift`, `initPaneSession()` in `PaneWorkspaceTerminalView`
- After `createSession` succeeds, update the layout tree leaf's `commandLine` with `KytosSettings.shared.resolvedCommandLine()`
- Call `KytosAppModel.shared.save()` so it persists across relaunches
- Existing known-issue in PLAN.md

**5b. Live foreground process name in navigator**
- File: `KytosPanelViews.swift` (already has process tree logic), `KytosApp.swift`
- Add a shared `@Published` dict `[UUID: String]` in `KytosTerminalManager` for foreground process names
- `KytosPanelViews` already polls process trees; write the leaf process name into this dict
- `PaneLeafRow` observes this dict to update its label without a full SwiftUI body refresh

---

### Phase 6 — Nice-to-Have (P3)

**6a. Scrollback in snapshots (requires Pane patch)**
- Add a `--scrollback N` option to the pane attach command (patch in `Patches/Pane/`)
- Server includes up to N scrollback lines prepended to snapshot cells
- Client renders them into SwiftTerm's scrollback buffer using `ESC[S` / absolute cursor moves

**6b. `ansi256PaletteStrategy` auto-selection**
- When a custom `.itermcolors` palette is loaded, switch to `.base16Lab` automatically since the palette re-maps ANSI 0–15; `.base16Lab` maps 16–231 to perceptually-match those base 16 colors

**6c. Horizontal margin setting**
- Already in PLAN.md known-issues; wire `KytosSettings.shared.horizontalMargin` as padding around `PaneWorkspaceTerminalRepresentable` in `PaneWorkspaceTerminalView`

---

## File-by-File Change Summary

| File | Phases |
|------|--------|
| `KytosApp.swift` | 1a, 1c, 1d, 2b (via updateTerminalAppearance), 3a, 3b, 4b, 5a |
| `KytosPaneStreamingCoordinator.swift` | 1b, 4a, 4b, 4c |
| `KytosPaneClient.swift` | 2a, 2b, 2c, 2d, 2e, 2f |
| `KytosSettings.swift` | 3c |
| `KytosSettingsView.swift` | 3c |
| `KytosPanelViews.swift` | 5b |
| `Models.swift` | 5a (commandLine persistence) |
| `Patches/Pane/` | 6a (new patch) |

---

## Priority Order

1. **P0 (do first):** 1a, 1b, 1c, 2a, 2b, 2c — these are the visible artefacts users see constantly
2. **P0 (do next):** 1d, 2d, 2e, 2f — polish the rendering path
3. **P1:** 3a (blink), 3b (deduplicate), 4a, 4b, 4c — robustness
4. **P2:** 5a, 5b — navigator quality of life
5. **P3:** 6a, 6b, 6c — nice to have
