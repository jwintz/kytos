import SwiftUI
import KelyphosKit

enum KytosNavigatorTab: String, KelyphosPanel {
    case sessions = "Sessions"
    
    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String {
        switch self {
        case .sessions: return "terminal"
        }
    }
    
    @ViewBuilder
    var body: some View {
        switch self {
        case .sessions:
            KytosSessionsSidebar()
        }
    }
}

enum KytosInspectorTab: String, CaseIterable, KelyphosPanel {
    case process = "Process Info"

    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String {
        switch self {
        case .process: return "info.circle"
        }
    }

    var body: some View {
        switch self {
        case .process:
            KytosProcessInfoView()
        }
    }
}


struct KytosFocusedWindowIDKey: FocusedValueKey {
    typealias Value = UUID
}
extension FocusedValues {
    var kytosFocusedWindowID: UUID? {
        get { self[KytosFocusedWindowIDKey.self] }
        set { self[KytosFocusedWindowIDKey.self] = newValue }
    }
}

enum KytosUtilityTab: CaseIterable, KelyphosPanel {
    var id: String { "" }
    var title: String { "" }
    var systemImage: String { "" }
    var body: some View { EmptyView() }
}

struct KytosSessionsSidebar: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var liveSessions: [String: KytosPaneSessionInfo] = [:]
    @State private var foregroundProcessNames: [UUID: String] = [:]
    @State private var trackedFocusedID: UUID?

    // Single consolidated timer for sidebar updates (was 3 separate timers at 0.3s/1s/5s)
    private static let sidebarTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var sessionRefreshCounter: Int = 0

    var body: some View {
        @Bindable var workspaceBindable = workspace

        List {
            Section(header: Text("Session")) {
                HStack {
                    Image(systemName: "terminal")
                    TextField("Session Name", text: $workspaceBindable.session.name)
                        .textFieldStyle(.plain)
                }
            }

            let leaves = workspaceBindable.session.layout.allTerminalLeaves()
            Section(header: Text("Panes")) {
                if leaves.isEmpty {
                    Text("No panes")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                } else {
                    ForEach(leaves, id: \.id) { leaf in
                        PaneLeafRow(
                            terminalID: leaf.id,
                            commandLine: leaf.commandLine,
                            foregroundProcess: foregroundProcessNames[leaf.id],
                            sessionInfo: leaf.sessionID.flatMap { liveSessions[$0] },
                            isFocused: leaf.id == trackedFocusedID,
                            onFocus: {
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("KytosRequestFocus"),
                                    object: leaf.id
                                )
                            },
                            onKill: {
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("KytosWorkspaceAction"),
                                    object: nil,
                                    userInfo: ["action": "closePane", "id": leaf.id]
                                )
                            }
                        )
                    }
                }
            }

            // Orphaned: live pane sessions not referenced by any layout leaf in this workspace
            let attachedIDs = Set(leaves.compactMap(\.sessionID))
            let orphaned = liveSessions.values.filter { !attachedIDs.contains($0.id) }
            if !orphaned.isEmpty {
                Section(header: Text("Orphaned")) {
                    ForEach(Array(orphaned), id: \.id) { session in
                        OrphanedSessionRow(
                            session: session,
                            onRevive: { reviveOrphan(session) },
                            onKill: { killSession(session.id) }
                        )
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { await refreshSessions() }
        .onReceive(Self.sidebarTimer) { _ in
            // Consolidated: track focus + refresh process names every 1s (was 0.3s + 1s)
            trackedFocusedID = KytosTerminalManager.shared.activeTerminalID
            refreshProcessNames()
            // Refresh sessions every 10s (was 5s) — counter-based to avoid extra timer
            sessionRefreshCounter += 1
            if sessionRefreshCounter >= 10 {
                sessionRefreshCounter = 0
                Task { await refreshSessions() }
            }
        }
    }

    @MainActor
    private func refreshSessions() async {
        let result = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                cont.resume(returning: Result { try KytosPaneClient.shared.listSessions() })
            }
        }
        if case .success(let sessions) = result {
            liveSessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        }
    }

    @MainActor
    private func refreshProcessNames() {
        let leaves = workspace.session.layout.allTerminalLeaves()
        var updated: [UUID: String] = [:]
        for leaf in leaves {
            if let name = KytosTerminalManager.shared.foregroundProcessName(for: leaf.id) {
                updated[leaf.id] = name
            }
        }
        foregroundProcessNames = updated
    }

    private func killSession(_ id: String) {
        DispatchQueue.global(qos: .background).async {
            try? KytosPaneClient.shared.destroySession(id: id)
            Task { @MainActor in await refreshSessions() }
        }
    }

    /// Revive an orphaned pane session by adding it as a new split in the current layout.
    private func reviveOrphan(_ session: KytosPaneSessionInfo) {
        let newID = UUID()
        let newLeaf = PaneLayoutTree.terminal(id: newID, commandLine: nil, paneSessionID: session.id)
        workspace.session.layout = .split(
            axis: .horizontal,
            left: workspace.session.layout,
            right: newLeaf
        )
        KytosAppModel.shared.save()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: newID)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: NSNotification.Name("KytosLayoutChanged"), object: nil)
        }
    }
}

private struct PaneLeafRow: View {
    let terminalID: UUID
    let commandLine: [String]?
    let foregroundProcess: String?
    let sessionInfo: KytosPaneSessionInfo?
    let isFocused: Bool
    let onFocus: () -> Void
    let onKill: () -> Void
    @State private var isHovered = false

    /// Human-readable label: last path component of the shell (e.g. "zsh"), falling back to "Shell"
    private var commandLabel: String {
        guard let cmd = commandLine?.first, !cmd.isEmpty else { return "Shell" }
        return URL(fileURLWithPath: cmd).lastPathComponent
    }

    /// Primary label: foreground process when different from the shell, else shell name.
    private var primaryLabel: String {
        if let fp = foregroundProcess, !fp.isEmpty, fp != commandLabel { return fp }
        return commandLabel
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sessionInfo?.isRunning == true ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryLabel)
                    .font(.system(size: 12))
                    .fontWeight(isFocused ? .semibold : .regular)
                    .lineLimit(1)
                if let sid = sessionInfo?.id {
                    Text(commandLabel == primaryLabel ? "pane session \(sid)" : "\(commandLabel) — \(sid)")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("connecting…")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if isFocused {
                Image(systemName: "scope")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
            }
            Button(action: onKill) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Close pane")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .glassEffect(in: RoundedRectangle(cornerRadius: 6))
        .opacity(isHovered ? 1.0 : 0.85)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onFocus)
    }
}

private struct OrphanedSessionRow: View {
    let session: KytosPaneSessionInfo
    let onRevive: () -> Void
    let onKill: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(Color.secondary.opacity(0.5), lineWidth: 1)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.name ?? "Session \(session.id)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("Orphaned")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isHovered {
                Button(action: onRevive) {
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .help("Revive session")
            }
            Button(action: onKill) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovered ? 1 : 0)
            .help("Kill orphaned session")
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .glassEffect(in: RoundedRectangle(cornerRadius: 6))
        .opacity(isHovered ? 1.0 : 0.85)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onRevive)
    }
}

import AppKit
import Darwin
typealias PlatformViewRepresentable = NSViewRepresentable
import SwiftTerm

typealias OSColor = NSColor

func loadITermColors(from url: URL, into terminalView: TerminalView) {
    guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return }
    
    func parseColor(_ dictName: String) -> OSColor? {
        guard let colorDict = dict[dictName] as? [String: Any],
              let r = colorDict["Red Component"] as? CGFloat,
              let g = colorDict["Green Component"] as? CGFloat,
              let b = colorDict["Blue Component"] as? CGFloat else { return nil }
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }
    
    if let bg = parseColor("Background Color") {
        // terminalView.nativeBackgroundColor = bg
        // terminalView.layer?.backgroundColor = bg.cgColor
    }
    if let fg = parseColor("Foreground Color") {
        terminalView.nativeForegroundColor = fg
    }
    if let cursor = parseColor("Cursor Color") {
        terminalView.caretColor = cursor
    }
    if let selection = parseColor("Selection Color") {
        terminalView.selectedTextBackgroundColor = selection
    }
    
    var ansiColors: [SwiftTerm.Color] = []
    for i in 0..<16 {
        if let colorDict = dict["Ansi \(i) Color"] as? [String: Any],
           let r = colorDict["Red Component"] as? CGFloat,
           let g = colorDict["Green Component"] as? CGFloat,
           let b = colorDict["Blue Component"] as? CGFloat {
            ansiColors.append(SwiftTerm.Color(red: UInt16(r * 65535), green: UInt16(g * 65535), blue: UInt16(b * 65535)))
        } else {
            ansiColors.append(SwiftTerm.Color(red: 0, green: 0, blue: 0))
        }
    }
    if ansiColors.count == 16 {
        terminalView.installColors(ansiColors)
    }
}

class MacOSLocalProcessTerminalCoordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate {
    
    // MARK: - LocalProcessDelegate Requirements
    func processTerminated(_ source: SwiftTerm.LocalProcess, exitCode: Int32?) {
        kLog("[KytosDebug] Shell Terminated with code: \(String(describing: exitCode))")
        if let id = terminalID {
            KytosTerminalManager.shared.removeTerminal(id: id)
        }
    }
    func dataReceived(slice: ArraySlice<UInt8>) {
        terminalView?.feed(byteArray: slice)
    }
    func getWindowSize() -> winsize {
        guard let terminal = terminalView?.terminal else { return winsize() }
        let f: CGRect = terminalView!.frame
        // Clamp to avoid negative-value crash (UInt16) during layout transitions after pane close.
        let w = UInt16(max(0, f.width))
        let h = UInt16(max(0, f.height))
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: w, ws_ypixel: h)
    }
    
    // MARK: - TerminalViewDelegate Requirements
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard newCols > 0, newRows > 0, newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows
        kLog("[KytosDebug] TerminalView sizeChanged: cols=\(newCols), rows=\(newRows)")
        guard process.running else { return }
        var size = getWindowSize()
        let _ = PseudoTerminalHelpers.setWinSize(masterPtyDescriptor: process.childfd, windowSize: &size)
    }
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {
        process.send(data: data)
    }
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
    
    var terminalView: TerminalView?
    lazy var process = LocalProcess(delegate: self)
    var terminalID: UUID?
    var lastCols: Int = -1
    var lastRows: Int = -1
    
    func start(commandLine: [String]? = nil) {
        let shell: String
        if let exe = commandLine?.first {
            shell = exe
        } else {
            shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        }

        var environment = ProcessInfo.processInfo.environment
        let args: [String] = ["-l"]

        kLog("[KytosDebug] Starting shell: \(shell)")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["SHELL"] = shell
        let envArray = environment.map { "\($0.key)=\($0.value)" }
        let home = environment["HOME"] ?? NSHomeDirectory()
        process.startProcess(executable: shell, args: args, environment: envArray, currentDirectory: home)
        kLog("[KytosDebug] Shell launched calling startProcess")
    }
}

struct FocusedTerminalIDKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var kytosFocusedTerminalID: UUID? {
        get { self[FocusedTerminalIDKey.self] }
        set { self[FocusedTerminalIDKey.self] = newValue }
    }
}

struct PaneWorkspaceTerminalRepresentable: PlatformViewRepresentable {
    let terminalID: UUID
    let commandLine: [String]?
    let paneSessionID: String?
    let colorScheme: ColorScheme
    let settings: KytosSettings

    // MARK: - Coordinator

    /// Holds per-instance state that must survive SwiftUI re-renders.
    class Coordinator {
        /// KytosLayoutChanged observer token — removed in deinit to prevent stacking.
        var layoutObserver: NSObjectProtocol?
        /// KytosRetryStream observer token — removed in deinit to prevent stacking.
        var retryObserver: NSObjectProtocol?
        /// Hash of last-applied appearance settings; prevents redundant redraws.
        var lastSettingsHash: Int = 0

        deinit {
            if let obs = layoutObserver { NotificationCenter.default.removeObserver(obs) }
            if let obs = retryObserver  { NotificationCenter.default.removeObserver(obs) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Appearance

    private func settingsHash() -> Int {
        var hasher = Hasher()
        hasher.combine(colorScheme)
        hasher.combine(settings.fontFamily)
        hasher.combine(settings.fontSize)
        hasher.combine(settings.cursorBlink)
        hasher.combine(String(describing: settings.cursorStyle))
        hasher.combine(settings.ansi256Palette == .base16Lab)
        return hasher.finalize()
    }

    private func updateTerminalAppearance(_ view: TerminalView) {
        let colorName = colorScheme == .dark ? "Kytos-dark" : "Kytos-light"
        let colorFileLoaded: Bool
        if let url = Bundle.main.url(forResource: colorName, withExtension: "itermcolors") {
            loadITermColors(from: url, into: view)
            colorFileLoaded = true
        } else {
            colorFileLoaded = false
        }
        view.font = settings.nsFont
        // Combine shape and blink into a single CursorStyle value.
        let effectiveStyle: CursorStyle
        switch settings.cursorStyle {
        case .steadyBlock:     effectiveStyle = settings.cursorBlink ? .blinkBlock     : .steadyBlock
        case .steadyUnderline: effectiveStyle = settings.cursorBlink ? .blinkUnderline : .steadyUnderline
        case .steadyBar:       effectiveStyle = settings.cursorBlink ? .blinkBar       : .steadyBar
        default:               effectiveStyle = .steadyBlock
        }
        view.terminal.setCursorStyle(effectiveStyle)
        // When a custom .itermcolors palette is loaded, default to base16Lab so the
        // 240 extended xterm colors are mapped to perceptually match the 16-color palette.
        // The user's explicit picker choice is respected only when no custom palette is active.
        view.terminal.ansi256PaletteStrategy = colorFileLoaded ? .base16Lab : settings.ansi256Palette
        view.needsDisplay = true
    }

    // MARK: - iOS

    func makeUIView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(
            id: terminalID, colorScheme: colorScheme,
            commandLine: commandLine, paneSessionID: paneSessionID).view
        context.coordinator.lastSettingsHash = settingsHash()
        updateTerminalAppearance(terminal)
        return terminal
    }

    func updateUIView(_ uiView: TerminalView, context: Context) {
        let hash = settingsHash()
        guard hash != context.coordinator.lastSettingsHash else { return }
        context.coordinator.lastSettingsHash = hash
        updateTerminalAppearance(uiView)
    }

    // MARK: - macOS
    func makeNSView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(
            id: terminalID, colorScheme: colorScheme,
            commandLine: commandLine, paneSessionID: paneSessionID).view
        context.coordinator.lastSettingsHash = settingsHash()
        updateTerminalAppearance(terminal)
        // Re-trigger sizeChanged after layout changes (e.g. new splits).
        // Token stored in coordinator so the observer is removed when the view is torn down.
        context.coordinator.layoutObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("KytosLayoutChanged"), object: nil, queue: .main
        ) { [weak terminal] _ in
            guard let tv = terminal else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                tv.needsLayout = true
                tv.layoutSubtreeIfNeeded()
            }
        }

        // KytosRetryStream: the stream-failed overlay calls this with the terminal UUID.
        // Route it to the streaming coordinator's retry() method.
        let tid = terminalID
        context.coordinator.retryObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("KytosRetryStream"), object: nil, queue: .main
        ) { [weak terminal] notification in
            guard let failedID = notification.object as? UUID, failedID == tid else { return }
            guard let coord = KytosTerminalManager.shared.coordinator(for: tid) as? KytosPaneStreamingCoordinator else {
                // Fallback: force layout so sizeChanged can reconnect.
                terminal?.needsLayout = true
                terminal?.layoutSubtreeIfNeeded()
                return
            }
            coord.retry()
        }
        return terminal
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        let hash = settingsHash()
        guard hash != context.coordinator.lastSettingsHash else { return }
        context.coordinator.lastSettingsHash = hash
        updateTerminalAppearance(nsView)
    }
}

class KytosTerminalManager {
    static let shared = KytosTerminalManager()

    init() {
        // Use NSWindow.didBecomeKeyNotification + didResignKeyNotification to latch
        // whichever TerminalView is the first responder, replacing 0.1s polling timer.
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak self] _ in
            _ = self?.activeTerminalID
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            _ = self?.activeTerminalID
        }
    }
    
    struct ManagedTerminal {
        let view: TerminalView
        let coordinator: MacOSLocalProcessTerminalCoordinator
    }
    
    private var terminals: [UUID: ManagedTerminal] = [:]
    /// Maps terminal UUIDs to their pane session IDs for reconnection after stream drops.
    private var terminalSessionIDs: [UUID: String] = [:]
    /// Per-pane font size overrides (nil = use global KytosSettings.shared.fontSize)
    private var fontSizeOverrides: [UUID: CGFloat] = [:]

    func fontSizeForPane(_ id: UUID) -> CGFloat {
        fontSizeOverrides[id] ?? KytosSettings.shared.fontSize
    }

    func adjustFontSize(for id: UUID, delta: CGFloat) {
        let current = fontSizeForPane(id)
        fontSizeOverrides[id] = min(max(current + delta, 8), 36)
        // Trigger view update
        if let tv = terminals[id]?.view {
            let size = fontSizeOverrides[id]!
            let fontName = KytosSettings.shared.fontFamily
            tv.font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    func resetFontSize(for id: UUID) {
        fontSizeOverrides.removeValue(forKey: id)
        if let tv = terminals[id]?.view {
            let size = KytosSettings.shared.fontSize
            let fontName = KytosSettings.shared.fontFamily
            tv.font = NSFont(name: fontName, size: size) ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Guards against multiple concurrent session creations.
    /// Ensures only one terminal creates at a time, preventing race conditions
    /// where two terminals both get the same session ID from the server.
    private var sessionCreationInFlight: Set<UUID> = []
    private let creationLock = NSLock()
    /// Global creation semaphore — only one session can be created at a time.
    private var globalCreationInFlight = false

    /// Attempts to claim the right to create a pane session.
    /// Returns `true` if the caller should proceed; `false` if another creation is in flight.
    func claimSessionCreation(for id: UUID) -> Bool {
        creationLock.lock()
        defer { creationLock.unlock() }
        guard !globalCreationInFlight else { return false }
        guard sessionCreationInFlight.insert(id).inserted else { return false }
        globalCreationInFlight = true
        return true
    }

    /// Releases the creation claim after the session has been created (or failed).
    func releaseSessionCreation(for id: UUID) {
        creationLock.lock()
        defer { creationLock.unlock() }
        sessionCreationInFlight.remove(id)
        globalCreationInFlight = false
    }

    func hasCreationClaim(for id: UUID) -> Bool {
        creationLock.lock()
        defer { creationLock.unlock() }
        return sessionCreationInFlight.contains(id)
    }

    /// The last terminal that was the key window's first responder.
    /// Unlike `activeTerminalID`, this does NOT clear when a non-terminal (e.g., search field) gets focus,
    /// so inspector/utility views can safely use it while the user types in their own fields.
    var lastKnownActiveTerminalID: UUID?

    var activeTerminalID: UUID? {
        guard let firstResponder = NSApplication.shared.keyWindow?.firstResponder as? TerminalView else { return nil }
        let found = terminals.first(where: { $0.value.view === firstResponder })?.key
        if let found { lastKnownActiveTerminalID = found }
        return found
    }

    /// Call this immediately after making a terminal the first responder so the latch
    /// is set even before any poll timer fires.
    func recordFocus(id: UUID) {
        lastKnownActiveTerminalID = id
    }

    /// Close all streaming connections to break blocking reads during app quit.
    func disconnectAll() {
        for (_, managed) in terminals {
            if let streaming = managed.coordinator as? KytosPaneStreamingCoordinator {
                streaming.disconnect()
            }
        }
    }
    
    func getOrCreateTerminal(id: UUID, colorScheme: ColorScheme, commandLine: [String]? = nil, paneSessionID: String? = nil) -> ManagedTerminal {
        if let existing = terminals[id] {
            return existing
        }
        kLog("[KytosDebug][TermMgr] getOrCreateTerminal id=\(id.uuidString.prefix(8)) paneSessionID=\(paneSessionID ?? "nil")")
        let coordinator: MacOSLocalProcessTerminalCoordinator = paneSessionID != nil
            ? KytosPaneStreamingCoordinator()
            : MacOSLocalProcessTerminalCoordinator()
        coordinator.terminalID = id
        
        // Use .zero — SwiftUI layout delivers the real size before the first sizeChanged,
        // preventing a spurious 800×600 resize being sent to the pane server.
        let terminal = TerminalView(frame: .zero)
        // NOTE: scrollback is applied later in sizeChanged (after setupOptions runs)
        // because setupOptions creates fresh TerminalOptions with default scrollback.
        terminal.autoresizingMask = [.width, .height]
        terminal.setContentHuggingPriority(.defaultLow, for: .horizontal)
        terminal.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        
        // Colors, font, and cursor style are applied by updateTerminalAppearance in the
        // representable's makeNSView/makeUIView immediately after getOrCreateTerminal returns.
        // No need to call loadITermColors here; doing so would apply colors twice.

        terminal.nativeBackgroundColor = .clear
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.layer?.isOpaque = false
        
        coordinator.terminalView = terminal
        terminal.terminalDelegate = coordinator
        // Check for session ID collision: if another terminal already has this session ID,
        // clear it to prevent both terminals sharing the same pane session.
        var effectiveSID = paneSessionID
        if let sid = effectiveSID {
            let collision = terminalSessionIDs.first { $0.key != id && $0.value == sid }
            if collision != nil {
                kLog("[KytosDebug][TermMgr] session \(sid) collision — already used by \(collision!.key.uuidString.prefix(8)), clearing for \(id.uuidString.prefix(8))")
                effectiveSID = nil
            }
        }
        if let sid = effectiveSID, let streamCoord = coordinator as? KytosPaneStreamingCoordinator {
            // Don't call startStream yet — defer to the first sizeChanged so we
            // attach at the real terminal dimensions, not the 800×600 default.
            streamCoord.pendingSessionID = sid
            KytosTerminalManager.shared.registerSessionID(sid, for: id)
        } else {
            coordinator.start(commandLine: commandLine)
        }
        
        // Listen for internal routing to become first responder
        NotificationCenter.default.addObserver(forName: NSNotification.Name("KytosRequestFocus"), object: nil, queue: .main) { [weak terminal] notification in
            guard let terminal = terminal,
                  let requestedID = notification.object as? UUID,
                  requestedID == coordinator.terminalID else { return }
            let hasWindow = terminal.window != nil
            kLog("[KytosDebug][Focus] KytosRequestFocus for \(requestedID.uuidString.prefix(8)) — hasWindow=\(hasWindow)")
            if let window = terminal.window {
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(terminal)
                KytosTerminalManager.shared.recordFocus(id: requestedID)
                kLog("[KytosDebug][Focus]   → makeFirstResponder called, firstResponder=\(window.firstResponder === terminal)")
            } else {
                kLog("[KytosDebug][Focus]   → NO WINDOW, will retry")
                // Retry with increasing delays until the terminal is in a window
                func retryFocus(attempt: Int) {
                    let delays: [Double] = [0.1, 0.2, 0.4, 0.8]
                    guard attempt < delays.count else {
                        kLog("[KytosDebug][Focus]   → gave up after \(attempt) retries for \(requestedID.uuidString.prefix(8))")
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + delays[attempt]) { [weak terminal] in
                        guard let terminal = terminal else { return }
                        if let window = terminal.window {
                            window.makeKeyAndOrderFront(nil)
                            window.makeFirstResponder(terminal)
                            KytosTerminalManager.shared.recordFocus(id: requestedID)
                            kLog("[KytosDebug][Focus]   → retry \(attempt) succeeded for \(requestedID.uuidString.prefix(8))")
                        } else {
                            kLog("[KytosDebug][Focus]   → retry \(attempt) no window for \(requestedID.uuidString.prefix(8))")
                            retryFocus(attempt: attempt + 1)
                        }
                    }
                }
                retryFocus(attempt: 0)
            }
        }

        // Focus when loaded — use window.didBecomeKeyNotification to avoid
        // timing races with window readiness (see DIAGNOSIS.md).
        let termIDForLog = id
        var becameKeyObserver: NSObjectProtocol?
        
        func applyInitialFocus(_ terminal: TerminalView) {
            guard let window = terminal.window else { return }
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(terminal)
            KytosTerminalManager.shared.recordFocus(id: termIDForLog)
            kLog("[KytosDebug][Focus] Initial focus for \(termIDForLog.uuidString.prefix(8)) — firstResponder=\(window.firstResponder === terminal)")
        }
        
        // Try immediately if window is already available
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak terminal] in
            guard let terminal = terminal else { return }
            if terminal.window != nil {
                applyInitialFocus(terminal)
                if let obs = becameKeyObserver {
                    NotificationCenter.default.removeObserver(obs)
                    becameKeyObserver = nil
                }
            }
        }
        
        // Also listen for window becoming key (handles the case where window
        // isn't ready yet when the terminal is created).
        becameKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { [weak terminal] notification in
            guard let terminal = terminal,
                  let window = notification.object as? NSWindow,
                  terminal.window === window else { return }
            applyInitialFocus(terminal)
            // Only need this once
            if let obs = becameKeyObserver {
                NotificationCenter.default.removeObserver(obs)
                becameKeyObserver = nil
            }
        }
        
        // Safety: remove observer if terminal is deallocated before window becomes key
        // (the observer captures terminal weakly so it will just bail out)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
            if let obs = becameKeyObserver {
                NotificationCenter.default.removeObserver(obs)
                becameKeyObserver = nil
            }
        }
        
        let managed = ManagedTerminal(view: terminal, coordinator: coordinator)
        terminals[id] = managed
        return managed
    }
    
    func getExistingTerminal(id: UUID) -> ManagedTerminal? {
        return terminals[id]
    }

    func coordinator(for id: UUID) -> MacOSLocalProcessTerminalCoordinator? {
        terminals[id]?.coordinator
    }

    func removeTerminal(id: UUID) {
        terminals.removeValue(forKey: id)
        terminalSessionIDs.removeValue(forKey: id)
    }

    func sessionID(for id: UUID) -> String? {
        terminalSessionIDs[id]
    }

    func registerSessionID(_ sessionID: String, for terminalID: UUID) {
        terminalSessionIDs[terminalID] = sessionID
    }

    // MARK: - Active pane subtitle (process name — cwd)
    private var cachedSessionPIDs: [String: pid_t] = [:]

    /// Returns the window subtitle for the currently active pane: "process — ~/path".
    /// Safe to call from the main thread; PID lookup is synchronous but fast once cached.
    func activePaneSubtitle() -> String {
        guard let tid = lastKnownActiveTerminalID,
              let sid = terminalSessionIDs[tid] else { return "" }

        let shellPid: pid_t
        if let cached = cachedSessionPIDs[sid] {
            shellPid = cached
        } else {
            guard let info = (try? KytosPaneClient.shared.listSessions())?
                    .first(where: { $0.id == sid }),
                  let pid = info.processID else { return "" }
            cachedSessionPIDs[sid] = pid_t(pid)
            shellPid = pid_t(pid)
        }

        let cwd = kytosProcessCWD(shellPid) ?? ""
        let name = kytosProcessForegroundName(shellPid)
        let display = cwd.hasPrefix(NSHomeDirectory())
            ? "~" + cwd.dropFirst(NSHomeDirectory().count)
            : cwd
        return display.isEmpty ? name : "\(name) — \(display)"
    }

    /// Returns the name of the foreground process for the given terminal UUID, or nil if unknown.
    /// Suitable for polling from the navigator sidebar (reuses the same PID cache).
    func foregroundProcessName(for terminalID: UUID) -> String? {
        guard let sid = terminalSessionIDs[terminalID] else { return nil }
        let shellPid: pid_t
        if let cached = cachedSessionPIDs[sid] {
            shellPid = cached
        } else {
            guard let info = (try? KytosPaneClient.shared.listSessions())?
                    .first(where: { $0.id == sid }),
                  let pid = info.processID else { return nil }
            cachedSessionPIDs[sid] = pid_t(pid)
            shellPid = pid_t(pid)
        }
        return kytosProcessForegroundName(shellPid)
    }

    private func kytosProcessCWD(_ pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { ptr in
            String(cString: ptr.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    private func kytosProcessForegroundName(_ shellPid: pid_t) -> String {
        // Check for a foreground child process
        var childPids = [pid_t](repeating: 0, count: 32)
        let n = proc_listchildpids(shellPid, &childPids, Int32(MemoryLayout<pid_t>.size * 32))
        if n > 0 {
            var buf = [CChar](repeating: 0, count: 1024)
            proc_name(childPids[0], &buf, UInt32(buf.count))
            let childName = String(cString: &buf)
            if !childName.isEmpty { return childName }
        }
        var buf = [CChar](repeating: 0, count: 1024)
        proc_name(shellPid, &buf, UInt32(buf.count))
        return String(cString: &buf)
    }
}

struct PaneWorkspaceTerminalView: View {
    let terminalID: UUID
    let commandLine: [String]?
    let paneSessionID: String?
    @Binding var layout: PaneLayoutTree
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = KytosSettings.shared
    /// Resolved session ID — either from the layout or freshly created.
    @State private var resolvedSessionID: String?
    /// Set to true once we've attempted session creation (even if it failed).
    @State private var paneInitDone: Bool = false
    /// True when the streaming coordinator failed to obtain a snapshot (shows overlay).
    @State private var streamFailed: Bool = false

    var body: some View {
        Group {
            if paneInitDone {
                ZStack {
                    PaneWorkspaceTerminalRepresentable(
                        terminalID: terminalID,
                        commandLine: commandLine,
                        paneSessionID: resolvedSessionID,
                        colorScheme: colorScheme,
                        settings: settings
                    )
                    .padding(.horizontal, settings.horizontalMargin)
                    .background(Color.clear)

                    if streamFailed {
                        streamFailedOverlay
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosWorkspaceAction"))) { notification in
                    guard let userInfo = notification.userInfo,
                          let id = userInfo["id"] as? UUID,
                          id == terminalID,
                          let action = userInfo["action"] as? String else { return }
                    switch action {
                    case "splitHorizontal": split(axis: .horizontal)
                    case "splitVertical": split(axis: .vertical)
                    default: break
                    }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosStreamFailed"))) { notification in
                    guard let failedID = notification.object as? UUID, failedID == terminalID else { return }
                    streamFailed = true
                }
            } else {
                Color.clear
            }
        }
        .task { await initPaneSession() }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosPaneSessionReplaced"))) { notification in
            guard let userInfo = notification.userInfo,
                  let oldID = userInfo["oldID"] as? String,
                  let newID = userInfo["newID"] as? String,
                  resolvedSessionID == oldID else { return }
            resolvedSessionID = newID
            if case .terminal(let id, let cmd, _) = layout {
                layout = .terminal(id: id, commandLine: cmd, paneSessionID: newID)
                KytosTerminalManager.shared.registerSessionID(newID, for: id)
                KytosAppModel.shared.save()
            }
            kLog("[KytosDebug][initPaneSession] session replaced: \(oldID) → \(newID)")
        }
    }

    /// Overlay shown when the streaming coordinator failed to receive a snapshot.
    @ViewBuilder private var streamFailedOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.yellow)
                Text("Stream failed")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("The terminal could not receive its initial screen state.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                Button("Retry") {
                    streamFailed = false
                    NotificationCenter.default.post(
                        name: NSNotification.Name("KytosRetryStream"),
                        object: terminalID)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(20)
        }
        .allowsHitTesting(true)
        .transition(.opacity)
    }

    @MainActor
    private func initPaneSession() async {
        // Wait for reconciliation to finish clearing dead/duplicate session IDs
        // before using any persisted paneSessionID.
        await KytosAppModel.shared.waitForReconciliation()
        // Read session ID from the canonical KytosAppModel (the @Binding may be
        // stale after reconciliation replaced the entire layout tree).
        let currentSessionID: String? = KytosAppModel.shared.windows.values
            .lazy.compactMap { $0.session.layout.sessionID(for: terminalID) }
            .first
        kLog("[KytosDebug][initPaneSession] start — terminalID=\(terminalID.uuidString.prefix(8)), paneSessionID=\(currentSessionID ?? "nil")")
        if let existing = currentSessionID {
            resolvedSessionID = existing
            paneInitDone = true
            kLog("[KytosDebug][initPaneSession] using existing session: \(existing)")
            return
        }
        // Prevent duplicate session creation — global lock ensures sequential creation.
        if !KytosTerminalManager.shared.claimSessionCreation(for: terminalID) {
            kLog("[KytosDebug][initPaneSession] creation in flight, waiting — \(terminalID.uuidString.prefix(8))")
            var claimed = false
            for _ in 0..<10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if case .terminal(_, _, let sid?) = layout {
                    resolvedSessionID = sid
                    paneInitDone = true
                    kLog("[KytosDebug][initPaneSession] picked up session \(sid) after wait — \(terminalID.uuidString.prefix(8))")
                    return
                }
                if KytosTerminalManager.shared.claimSessionCreation(for: terminalID) {
                    claimed = true
                    kLog("[KytosDebug][initPaneSession] claimed after wait — \(terminalID.uuidString.prefix(8))")
                    break
                }
            }
            if !claimed {
                kLog("[KytosDebug][initPaneSession] gave up waiting — \(terminalID.uuidString.prefix(8))")
                paneInitDone = true
                return
            }
        }
        defer { KytosTerminalManager.shared.releaseSessionCreation(for: terminalID) }

        // Double-check: the layout may have been updated by another view instance.
        if case .terminal(_, _, let sid?) = layout {
            resolvedSessionID = sid
            paneInitDone = true
            return
        }

        // Create a new pane session on a background thread (blocking socket call).
        let cmdLine = commandLine ?? KytosSettings.shared.resolvedCommandLine()
        kLog("[KytosDebug][initPaneSession] creating session with cmdLine: \(cmdLine.joined(separator: " "))")
        let newSessionID: String? = await Task.detached(priority: .userInitiated) {
            kLog("[KytosDebug][initPaneSession] createSession on detached task")
            do {
                let info = try KytosPaneClient.shared.createSession(commandLine: cmdLine)
                kLog("[KytosDebug][initPaneSession] createSession returned: \(info.id)")
                return info.id
            } catch {
                kLog("[KytosDebug][initPaneSession] createSession FAILED: \(error)")
                return nil as String?
            }
        }.value
        if let sid = newSessionID {
            resolvedSessionID = sid
            kLog("[KytosDebug][initPaneSession] created session: \(sid)")
            // Persist the session ID and the resolved command line back into the layout tree.
            // Storing cmdLine (not just cmd) ensures the navigator shows the real shell name
            // rather than "Shell" for panes started without an explicit commandLine.
            if case .terminal(let id, _, nil) = layout {
                layout = .terminal(id: id, commandLine: cmdLine, paneSessionID: sid)
                KytosAppModel.shared.save()
            }
        }
        paneInitDone = true
    }
    
    private func split(axis: PaneLayoutTree.Axis) {
        let newID = UUID()
        kLog("[KytosDebug][Split] axis=\(axis), existingID=\(terminalID.uuidString.prefix(8)), newID=\(newID.uuidString.prefix(8))")
        let newTree = PaneLayoutTree.split(
            axis: axis,
            left: .terminal(id: terminalID, commandLine: commandLine, paneSessionID: resolvedSessionID),
            right: .terminal(id: newID, commandLine: KytosSettings.shared.resolvedCommandLine())
        )
        layout = newTree
        KytosAppModel.shared.save()
        // Resign focus on the old terminal so its cursor becomes hollow
        if let oldTerminal = KytosTerminalManager.shared.getExistingTerminal(id: terminalID)?.view,
           let window = oldTerminal.window {
            kLog("[KytosDebug][Split] Resigning focus on old terminal \(terminalID.uuidString.prefix(8))")
            window.makeFirstResponder(nil)
        }
        // Request focus on the new pane once its stream is attached
        var focusObserver: NSObjectProtocol?
        focusObserver = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("KytosStreamAttached"),
            object: newID, queue: .main
        ) { _ in
            if let obs = focusObserver { NotificationCenter.default.removeObserver(obs) }
            kLog("[KytosDebug][Split] Stream attached, requesting focus for new pane \(newID.uuidString.prefix(8))")
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: newID)
        }
        // Fallback timeout in case the notification never fires
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if let obs = focusObserver { NotificationCenter.default.removeObserver(obs) }
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: newID)
        }
        // Tell all terminals to recalculate their size after the layout change settles
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            NotificationCenter.default.post(name: NSNotification.Name("KytosLayoutChanged"), object: nil)
        }
    }
}

struct PaneLayoutTreeView: View {
    @Binding var layout: PaneLayoutTree

    @State private var splitRatio: CGFloat = 0.5
    @State private var ratioLoaded: Bool = false

    private static let coordSpace = "paneSplitContainer"

    var body: some View {
        switch layout {
        case .empty:
            EmptyView()
        case .terminal(let id, let commandLine, let sessionID):
            PaneWorkspaceTerminalView(terminalID: id, commandLine: commandLine, paneSessionID: sessionID, layout: $layout)
                .id(id)
        case .split(let axis, let left, let right):
            let udKey = splitKey(left: left, right: right)
            let defaultRatio: CGFloat = CGFloat(left.leafCount) / CGFloat(left.leafCount + right.leafCount)

            PaneSplitLayout(axis: axis, ratio: splitRatio) {
                PaneLayoutTreeView(layout: Binding(
                    get: { if case .split(_, let l, _) = layout { return l }; return layout },
                    set: { updateLeft(to: $0) }
                ))
                splitDivider(axis: axis, udKey: udKey)
                PaneLayoutTreeView(layout: Binding(
                    get: { if case .split(_, _, let r) = layout { return r }; return layout },
                    set: { updateRight(to: $0) }
                ))
            }
            .coordinateSpace(name: Self.coordSpace)
            .background(GeometryReader { geo in
                Color.clear.onAppear { containerWidth = geo.size.width; containerHeight = geo.size.height }
                    .onChange(of: geo.size) { _, newSize in containerWidth = newSize.width; containerHeight = newSize.height }
            })
            .onAppear {
                if !ratioLoaded {
                    let stored = UserDefaults.standard.double(forKey: udKey)
                    splitRatio = stored > 0.01 ? CGFloat(stored) : defaultRatio
                    ratioLoaded = true
                }
            }
        }
    }

    // MARK: - Divider

    @ViewBuilder
    private func splitDivider(axis: PaneLayoutTree.Axis, udKey: String) -> some View {
        let drag = DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.coordSpace))
            .onChanged { value in
                // Use value.location — absolute position in container — for linear, lag-free tracking.
                if axis == .horizontal {
                    // The container's coordinate space starts at 0,0 top-left.
                    // We need the container width. GeometryReader would add a frame,
                    // but we can read it from the Layout's proposal via a preference.
                    splitRatio = max(0.10, min(0.90, value.location.x / max(1, containerWidth)))
                } else {
                    splitRatio = max(0.10, min(0.90, value.location.y / max(1, containerHeight)))
                }
            }
            .onEnded { _ in
                UserDefaults.standard.set(Double(splitRatio), forKey: udKey)
            }

        // 5px visible bar, 11px hit area
        if axis == .horizontal {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 5)
                .contentShape(Rectangle().size(width: 11, height: .infinity))
                .gesture(drag)
                .onHover { h in if h { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        } else {
            Rectangle()
                .fill(Color.secondary.opacity(0.3))
                .frame(height: 5)
                .contentShape(Rectangle().size(width: .infinity, height: 11))
                .gesture(drag)
                .onHover { h in if h { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
        }
    }

    // Container size read from preference set by PaneSplitLayout helper.
    @State private var containerWidth: CGFloat = 800
    @State private var containerHeight: CGFloat = 600

    // MARK: - Helpers

    private func splitKey(left: PaneLayoutTree, right: PaneLayoutTree) -> String {
        let l = left.firstLeafID()?.uuidString ?? "l"
        let r = right.firstLeafID()?.uuidString ?? "r"
        return "kytos.split.\(l).\(r)"
    }

    private func updateLeft(to newLayout: PaneLayoutTree) {
        if case .split(let axis, _, let right) = layout {
            layout = .split(axis: axis, left: newLayout, right: right)
        }
    }

    private func updateRight(to newLayout: PaneLayoutTree) {
        if case .split(let axis, let left, _) = layout {
            layout = .split(axis: axis, left: left, right: newLayout)
        }
    }
}

/// Custom Layout for binary pane splits. Reports `sizeThatFits` as the full proposal —
/// no min-size pushback — preventing the NavigationSplitView constraint feedback loop
/// (`_layoutSubtreeWithOldSize` recursion) and allowing the window to shrink freely.
private struct PaneSplitLayout: Layout {
    let axis: PaneLayoutTree.Axis
    let ratio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let dividerThick: CGFloat = 5
        if axis == .horizontal {
            let avail = max(0, bounds.width - dividerThick)
            let leftW = max(40, min(avail - 40, avail * ratio))
            let rightW = avail - leftW
            subviews[0].place(at: bounds.origin,
                              proposal: .init(width: leftW, height: bounds.height))
            subviews[1].place(at: .init(x: bounds.minX + leftW, y: bounds.minY),
                              proposal: .init(width: dividerThick, height: bounds.height))
            subviews[2].place(at: .init(x: bounds.minX + leftW + dividerThick, y: bounds.minY),
                              proposal: .init(width: rightW, height: bounds.height))
        } else {
            let avail = max(0, bounds.height - dividerThick)
            let topH = max(40, min(avail - 40, avail * ratio))
            let bottomH = avail - topH
            subviews[0].place(at: bounds.origin,
                              proposal: .init(width: bounds.width, height: topH))
            subviews[1].place(at: .init(x: bounds.minX, y: bounds.minY + topH),
                              proposal: .init(width: bounds.width, height: dividerThick))
            subviews[2].place(at: .init(x: bounds.minX, y: bounds.minY + topH + dividerThick),
                              proposal: .init(width: bounds.width, height: bottomH))
        }
    }
}

private struct KytosWelcomeView: View {
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No open panes")
                .font(.title2)
                .foregroundStyle(.secondary)
            Button(action: onNewTerminal) {
                Label("New Terminal", systemImage: "plus.rectangle")
            }
            .buttonStyle(.bordered)
            .keyboardShortcut("n", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PaneWorkspaceView: View {
    @Environment(KytosWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspaceBindable = workspace

        let _ = kLog("[KytosDebug][PaneWorkspaceView] body — session=\(workspaceBindable.session.name)")

        Group {
            if workspaceBindable.session.layout.isEmpty {
                KytosWelcomeView {
                    workspaceBindable.session.layout = .terminal(id: UUID())
                    KytosAppModel.shared.save()
                }
            } else {
                PaneLayoutTreeView(layout: $workspaceBindable.session.layout)
                    .id(workspaceBindable.session.id)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosWorkspaceAction"))) { notification in
                guard let userInfo = notification.userInfo,
                      let action = userInfo["action"] as? String,
                      let id = userInfo["id"] as? UUID else { return }

                let rootLayout = workspaceBindable.session.layout

                if action.hasPrefix("nav") {
                    var direction: PaneLayoutTree.MoveDirection?
                    switch action {
                    case "navLeft": direction = .left
                    case "navRight": direction = .right
                    case "navUp": direction = .up
                    case "navDown": direction = .down
                    default: break
                    }
                    if let dir = direction {
                        if let nextID = rootLayout.neighbor(of: id, direction: dir) {
                            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: nextID)
                        }
                    }
                } else if action == "closePane" {
                    // Destroy the pane session if one is attached to this leaf.
                    if case .terminal(_, _, let sid?) = rootLayout.find(id: id) {
                        DispatchQueue.global(qos: .background).async {
                            try? KytosPaneClient.shared.destroySession(id: sid)
                        }
                    }
                    if let newLayout = rootLayout.removing(id: id) {
                        workspaceBindable.session.layout = newLayout
                        KytosAppModel.shared.save()
                        // Focus the nearest remaining pane so CMD+W doesn't accidentally close the window.
                        if let focusID = newLayout.firstLeafID() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: focusID)
                            }
                        }
                    } else {
                        // Last pane removed — close the window instead of leaving
                        // an empty shell (which triggers WindowGroup state restoration).
                        workspaceBindable.session.layout = .empty
                        KytosAppModel.shared.save()
                        DispatchQueue.main.async {
                            NSApplication.shared.keyWindow?.close()
                        }
                    }
                }
            }
    }
}

import Foundation

private let kLogPath = "/tmp/kytos-debug.log"
private let kLogLock = NSLock()

#if DEBUG
func kLog(_ msg: @autoclosure () -> String) {
    let line = "\(Date()) \(msg())\n"
    guard let data = line.data(using: .utf8) else { return }
    kLogLock.lock()
    defer { kLogLock.unlock() }
    if let fh = FileHandle(forWritingAtPath: kLogPath) {
        fh.seekToEndOfFile()
        fh.write(data)
        fh.closeFile()
    } else {
        FileManager.default.createFile(atPath: kLogPath, contents: data)
    }
}
#else
@inline(__always)
func kLog(_ msg: @autoclosure () -> String) {
    // No-op in release builds — avoids all UUID string formatting overhead
}
#endif

@main
struct KytosApp: App {
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var appModel = KytosAppModel.shared
    @State private var settingsShellState: KelyphosShellState = {
        let state = KelyphosShellState(persistencePrefix: "me.jwintz.kytos")
        return state
    }()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Ensure the app comes to the front when launched (e.g. via `open -W`).
        DispatchQueue.main.async {
            NSApplication.shared.activate()
        }

        // Enable native macOS window tabbing BEFORE any windows are created
        // This gives us Cmd+T → new tab, "Show Tab Bar", "Show All Tabs"
        NSWindow.allowsAutomaticWindowTabbing = true

        // Install the global key monitor once for the app lifetime.
        // TerminalView (first responder) consumes all keyDown events, so we
        // intercept here before they reach the view hierarchy.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.keyCode {
                case 13: // W — Close Pane (intercept before macOS closes the window)
                    kLog("[KytosDebug][KeyMonitor] Cmd+W intercepted — activeTerminalID=\(KytosTerminalManager.shared.activeTerminalID?.uuidString.prefix(8) ?? "nil")")
                    if let id = KytosTerminalManager.shared.activeTerminalID {
                        NotificationCenter.default.post(
                            name: NSNotification.Name("KytosWorkspaceAction"),
                            object: nil,
                            userInfo: ["action": "closePane", "id": id]
                        )
                        return nil
                    }
                case 24: // ⌘+ — Increase font size (active pane)
                    if let id = KytosTerminalManager.shared.lastKnownActiveTerminalID {
                        KytosTerminalManager.shared.adjustFontSize(for: id, delta: 1)
                    }
                    return nil
                case 27: // ⌘- — Decrease font size (active pane)
                    if let id = KytosTerminalManager.shared.lastKnownActiveTerminalID {
                        KytosTerminalManager.shared.adjustFontSize(for: id, delta: -1)
                    }
                    return nil
                case 15: // ⌘R — Reset font size (active pane)
                    if let id = KytosTerminalManager.shared.lastKnownActiveTerminalID {
                        KytosTerminalManager.shared.resetFontSize(for: id)
                    }
                    return nil
                default:
                    break
                }
            }
            return event
        }

        // Save workspace state only when app is about to quit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            kLog("[KytosDebug][App] willTerminate — disconnecting streams and saving state")
            KytosAppModel.shared.isTerminating = true
            KytosTerminalManager.shared.disconnectAll()
            KytosAppModel.shared.save()
        }

        // SIGTERM handler — willTerminateNotification doesn't fire for signals.
        // Signal handlers must only call async-signal-safe functions; AppKit is not safe here.
        // Use a pipe to wake the main run loop and perform the save there.
        signal(SIGTERM) { _ in
            // Schedule cleanup on the main queue — safe from a signal handler.
            DispatchQueue.main.async {
                KytosTerminalManager.shared.disconnectAll()
                KytosAppModel.shared.save()
                _exit(0)
            }
        }
    }
    
    var body: some Scene {
        mainWindowGroup
            .commands {
                KytosWorkspaceCommands()
                KelyphosCommands()
            }
        Settings {
            KytosSettingsWindowView(shellState: settingsShellState)
        }
    }
    
    private var mainWindowGroup: some Scene {
        WindowGroup("Kytos", id: "main", for: UUID.self) { $windowID in
            KytosWindowView(windowID: $windowID, appModel: appModel)
        }
    }
}

struct KytosWindowView: View {
    @Binding var windowID: UUID?
    @State private var stableID: UUID
    /// Nil until onAppear fires — prevents workspace creation during SwiftUI's speculative view evaluation.
    @State private var workspace: KytosWorkspace?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.kelyphosKeybindingRegistry) private var registry

    /// Per-window shell state. Appearance keys share the app prefix (so Settings changes propagate
    /// via kelyphosAppearanceDidChange notification); panel-visibility keys are scoped to this
    /// window's UUID so toggling the navigator in one window doesn't affect others.
    @State private var windowShellState: KelyphosShellState
    var appModel: KytosAppModel

    init(windowID: Binding<UUID?>, appModel: KytosAppModel) {
        self._windowID = windowID
        let resolvedID = windowID.wrappedValue ?? UUID()
        self._stableID = State(initialValue: resolvedID)
        self.appModel = appModel
        // windowShellState is initialized with a temporary prefix; it will be
        // re-created in onAppear once the workspace (with its stable session ID)
        // is available — see _createShellState(for:).
        self._windowShellState = State(initialValue: KelyphosShellState(
            persistencePrefix: "me.jwintz.kytos",
            panelPrefix: "me.jwintz.kytos.tmp"
        ))
        kLog("[KytosDebug][WindowView] init — windowID=\(windowID.wrappedValue?.uuidString.prefix(8) ?? "nil"), stableID=\(resolvedID.uuidString.prefix(8))")
    }

    var body: some View {
        ZStack {
            if let ws = workspace {
                windowContent(workspace: ws)
            }
        }
        .onDisappear {
            // onDisappear also fires during SwiftUI re-renders, so we don't remove here.
            // Workspace removal is handled by the NSWindow.willCloseNotification observer below.
        }
        .onAppear {
            // Create workspace only here — onAppear fires for real windows, not speculative views
            if workspace == nil {
                workspace = appModel.workspace(for: stableID)
            }
            // Re-create shell state keyed by the workspace's stable session ID.
            // The session ID is persisted in the model and survives across launches,
            // unlike the window UUID which may change on each relaunch.
            if let ws = workspace {
                let stablePrefix = "me.jwintz.kytos.session.\(ws.session.id.uuidString)"
                windowShellState = KelyphosShellState(
                    persistencePrefix: "me.jwintz.kytos",
                    panelPrefix: stablePrefix
                )
                kLog("[KytosDebug][WindowView] Panel state keyed to session \(ws.session.id.uuidString.prefix(8))")
            }
            kLog("[KytosDebug][WindowView] onAppear — windowID=\(windowID?.uuidString.prefix(8) ?? "nil"), stableID=\(stableID.uuidString.prefix(8))")
            kLog("[KytosDebug][WindowView] workspace: session=\(workspace?.session.name ?? "nil"), totalWorkspaces=\(appModel.windows.count)")
            if windowID == nil {
                windowID = stableID
                kLog("[KytosDebug][WindowView] Assigned windowID = stableID (\(stableID.uuidString.prefix(8)))")
            }
            // Remove workspace when the NSWindow actually closes (not just SwiftUI re-renders).
            let id = stableID
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
                guard !appModel.isTerminating else { return }
                guard let window = notification.object as? NSWindow,
                      !( window is NSPanel),
                      appModel.windowToID[ObjectIdentifier(window)] == id else { return }
                kLog("[KytosDebug][WindowView] NSWindow.willClose — removing workspace for \(id.uuidString.prefix(8))")
                appModel.windows.removeValue(forKey: id)
                appModel.save()
            }
            if !appModel.hasRestoredWindows {
                appModel.hasRestoredWindows = true
                kLog("[KytosDebug][Restore] First window appeared — scheduling restore check in 0.5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let unclaimed = appModel.windows.filter { !appModel.isWindowClaimed($0.key) }
                    kLog("[KytosDebug][Restore] Unclaimed workspaces: \(unclaimed.count) (total=\(appModel.windows.count), claimed=\(unclaimed.count == 0 ? appModel.windows.count : appModel.windows.count - unclaimed.count))")
                    for (savedID, ws) in unclaimed {
                        kLog("[KytosDebug][Restore] Opening window for savedID=\(savedID.uuidString.prefix(8)), session=\(ws.session.name)")
                        openWindow(id: "main", value: savedID)
                    }
                    // Re-apply saved tab group structure once the new windows have appeared.
                    let savedGroups = appModel.loadTabGroups()
                    if !savedGroups.isEmpty {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            for group in savedGroups where group.count > 1 {
                                let groupWindows = group.compactMap { uuid -> NSWindow? in
                                    NSApp.windows.first {
                                        !($0 is NSPanel) && $0.contentView != nil &&
                                        appModel.windowToID[ObjectIdentifier($0)] == uuid
                                    }
                                }
                                guard groupWindows.count > 1, let anchor = groupWindows.first else { continue }
                                for window in groupWindows.dropFirst() {
                                    kLog("[KytosDebug][Restore] Re-grouping \(appModel.windowToID[ObjectIdentifier(window)]?.uuidString.prefix(8) ?? "?") into tab group")
                                    anchor.addTabbedWindow(window, ordered: .above)
                                }
                                anchor.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    kLog("[KytosDebug][Restore] Pruning at 3s — claimed=\(appModel.windows.filter { appModel.isWindowClaimed($0.key) }.count)")
                    appModel.pruneOrphanedWorkspaces()
                }
            }
            windowShellState.title = "Kytos"
            registry.register(category: "Workspace", label: "Split Horizontal", shortcut: "⌘D")
            registry.register(category: "Workspace", label: "Split Vertical", shortcut: "⇧⌘D")
            registry.register(category: "Workspace", label: "Close Pane", shortcut: "⌘W")
            registry.register(category: "Workspace", label: "Navigate Left", shortcut: "⌘⌥←")
            registry.register(category: "Workspace", label: "Navigate Right", shortcut: "⌘⌥→")
            registry.register(category: "Workspace", label: "Navigate Up", shortcut: "⌘⌥↑")
            registry.register(category: "Workspace", label: "Navigate Down", shortcut: "⌘⌥↓")
            registry.register(category: "Workspace", label: "New Window", shortcut: "⌘N")
            registry.register(category: "Workspace", label: "New Tab", shortcut: "⌘T")
        }
    }

    @ViewBuilder
    private func windowContent(workspace: KytosWorkspace) -> some View {
        KelyphosShellView(
            state: windowShellState,
            configuration: KelyphosShellConfiguration(
                navigatorTabs: KytosNavigatorTab.allCases,
                inspectorTabs: KytosInspectorTab.allCases,
                utilityTabs: KytosUtilityTab.allCases,
                scrollable: false,
                detail: {
                    PaneWorkspaceView()
                }
            )
        )
        .environment(workspace)
        .focusedSceneValue(\.kytosFocusedWindowID, stableID)
        .background { WindowRegistrar(windowID: stableID) }
        .onReceive(Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()) { _ in
            windowShellState.subtitle = KytosTerminalManager.shared.activePaneSubtitle()
        }
        .onChange(of: windowShellState.navigatorVisible) { _, _ in
            refocusActiveTerminal()
            windowShellState.savePanelState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: NSNotification.Name("KytosLayoutChanged"), object: nil)
            }
        }
        .onChange(of: windowShellState.inspectorVisible) { _, _ in
            refocusActiveTerminal()
            windowShellState.savePanelState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: NSNotification.Name("KytosLayoutChanged"), object: nil)
            }
        }
        .onChange(of: windowShellState.utilityAreaVisible) { _, _ in
            windowShellState.savePanelState()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                NotificationCenter.default.post(name: NSNotification.Name("KytosLayoutChanged"), object: nil)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KelyphosCommandInvoked"))) { notification in
            guard let userInfo = notification.userInfo,
                  let label = userInfo["label"] as? String else { return }

            kLog("[KytosDebug][WindowView:\(stableID.uuidString.prefix(8))] KelyphosCommandInvoked: '\(label)'")

            if label == "Close Pane" {
                if let id = KytosTerminalManager.shared.activeTerminalID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "closePane", "id": id])
                }
            } else if label == "Split Horizontal" {
                if let id = KytosTerminalManager.shared.activeTerminalID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitHorizontal", "id": id])
                }
            } else if label == "Split Vertical" {
                if let id = KytosTerminalManager.shared.activeTerminalID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitVertical", "id": id])
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosWorkspaceAction"))) { notification in
            guard let userInfo = notification.userInfo,
                  let action = userInfo["action"] as? String else { return }

            kLog("[KytosDebug][WindowView:\(stableID.uuidString.prefix(8))] KytosWorkspaceAction: '\(action)'")

            // With flattened model, each window/tab IS one session.
            // "closeSession" = close this tab/window.
            if action == "closeSession" {
                NSApplication.shared.keyWindow?.performClose(nil)
            }
        }
    }

    /// Re-focus the last active terminal after sidebar toggles steal focus.
    private func refocusActiveTerminal() {
        guard let tid = KytosTerminalManager.shared.lastKnownActiveTerminalID else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: tid)
        }
    }
}

/// Zero-size background view that registers an NSWindow with KytosAppModel
/// so tab group structure can be snapshotted at quit time.
private struct WindowRegistrar: NSViewRepresentable {
    let windowID: UUID

    func makeNSView(context: Context) -> RegistrarView { RegistrarView(windowID: windowID) }
    func updateNSView(_ nsView: RegistrarView, context: Context) {}

    final class RegistrarView: NSView {
        let windowID: UUID
        init(windowID: UUID) {
            self.windowID = windowID
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            KytosAppModel.shared.registerWindow(window, for: windowID)
        }
    }
}

struct KytosWorkspaceCommands: Commands {
    @FocusedValue(\.kytosFocusedTerminalID) var focusedID
    @FocusedValue(\.kytosFocusedWindowID) var focusedWindowID
    @Environment(\.openWindow) var openWindow

    private var activeID: UUID? {
        KytosTerminalManager.shared.activeTerminalID ?? focusedID
    }

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Split Horizontal") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitHorizontal", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: .command)

            Button("Split Vertical") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitVertical", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Divider()

            Button("Close Pane") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "closePane", "id": id])
                }
            }
            // Cmd+W intercepted by local key monitor (TerminalView swallows keyDown)

            Divider()

            Button("New Window") {
                openWindow(id: "main", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)

            // Cmd+T is handled natively by macOS (NSWindow newWindowForTab:) via allowsAutomaticWindowTabbing.

            Divider()

            Button("Navigate Left") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navLeft", "id": id])
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])

            Button("Navigate Right") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navRight", "id": id])
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])

            Button("Navigate Up") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navUp", "id": id])
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button("Navigate Down") {
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navDown", "id": id])
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
