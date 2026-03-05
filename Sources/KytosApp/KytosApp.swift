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
            #if os(macOS)
            KytosProcessInfoView()
            #else
            EmptyView()
            #endif
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
    #if os(macOS)
    @State private var liveSessions: [String: KytosPaneSessionInfo] = [:]
    #endif
    @State private var trackedFocusedID: UUID?

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

            #if os(macOS)
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
                            sessionInfo: leaf.sessionID.flatMap { liveSessions[$0] },
                            isFocused: leaf.id == trackedFocusedID,
                            onFocus: {
                                NotificationCenter.default.post(
                                    name: NSNotification.Name("KytosRequestFocus"),
                                    object: leaf.id
                                )
                            },
                            onKill: leaf.sessionID.map { sid in { killSession(sid) } }
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
                        OrphanedSessionRow(session: session, onKill: { killSession(session.id) })
                    }
                }
            }
            #endif
        }
        .listStyle(.sidebar)
        #if os(macOS)
        .task { await refreshSessions() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await refreshSessions() }
        }
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            trackedFocusedID = KytosTerminalManager.shared.activeTerminalID
        }
        #endif
    }

    #if os(macOS)
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

    private func killSession(_ id: String) {
        DispatchQueue.global(qos: .background).async {
            try? KytosPaneClient.shared.destroySession(id: id)
            Task { @MainActor in await refreshSessions() }
        }
    }
    #endif
}

#if os(macOS)
private struct PaneLeafRow: View {
    let terminalID: UUID
    let commandLine: [String]?
    let sessionInfo: KytosPaneSessionInfo?
    let isFocused: Bool
    let onFocus: () -> Void
    let onKill: (() -> Void)?
    @State private var isHovered = false

    /// Human-readable label: last path component of the shell (e.g. "zsh"), falling back to "Shell"
    private var commandLabel: String {
        guard let cmd = commandLine?.first, !cmd.isEmpty else { return "Shell" }
        return URL(fileURLWithPath: cmd).lastPathComponent
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(sessionInfo?.isRunning == true ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(commandLabel)
                    .font(.system(size: 12))
                    .fontWeight(isFocused ? .semibold : .regular)
                    .lineLimit(1)
                if let sid = sessionInfo?.id {
                    Text("pane session \(sid)")
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
            if let kill = onKill {
                Button(action: kill) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .opacity(isHovered ? 1 : 0)
                .help("Kill session")
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isHovered ? Color.secondary.opacity(0.12) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onTapGesture(perform: onFocus)
    }
}

private struct OrphanedSessionRow: View {
    let session: KytosPaneSessionInfo
    let onKill: () -> Void

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
            Button(action: onKill) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Kill orphaned session")
        }
        .padding(.vertical, 2)
    }
}
#endif

#if os(macOS)
import AppKit
typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
typealias PlatformViewRepresentable = UIViewRepresentable
#endif
import SwiftTerm

#if os(macOS)
typealias OSColor = NSColor
#else
typealias OSColor = UIColor
#endif

func loadITermColors(from url: URL, into terminalView: TerminalView) {
    guard let dict = NSDictionary(contentsOf: url) as? [String: Any] else { return }
    
    func parseColor(_ dictName: String) -> OSColor? {
        guard let colorDict = dict[dictName] as? [String: Any],
              let r = colorDict["Red Component"] as? CGFloat,
              let g = colorDict["Green Component"] as? CGFloat,
              let b = colorDict["Blue Component"] as? CGFloat else { return nil }
        #if os(macOS)
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
        #else
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        #endif
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

#if os(macOS)
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
        let bundledMksh = Bundle.main.url(forAuxiliaryExecutable: "mksh_bin")?.path ?? Bundle.main.bundlePath + "/Contents/MacOS/mksh_bin"

        let shell: String
        if let exe = commandLine?.first {
            shell = exe
        } else {
            let userChoice = KytosSettings.shared.shellChoice
            shell = userChoice == .embeddedMksh
                ? bundledMksh
                : (ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        }

        var environment = ProcessInfo.processInfo.environment
        let args: [String] = ["-l"]

        if shell == bundledMksh {
            let rcPath = FileManager.default.temporaryDirectory.appendingPathComponent("kytos_mkshrc").path
            if !FileManager.default.fileExists(atPath: rcPath) {
                let rc = """
                if [ -r ~/.mkshrc ]; then
                    . ~/.mkshrc
                fi
                export PS1='\\001\\033[36m\\002kytos\\001\\033[0m\\002 \\001\\033[33m\\002❯\\001\\033[0m\\002 '
                """
                try? rc.write(toFile: rcPath, atomically: true, encoding: .utf8)
            }
            environment["ENV"] = rcPath
        }

        kLog("[KytosDebug] Starting shell: \(shell)")
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["SHELL"] = shell
        let envArray = environment.map { "\($0.key)=\($0.value)" }
        process.startProcess(executable: shell, args: args, environment: envArray)
        kLog("[KytosDebug] Shell launched calling startProcess")
    }
}
#else
// iOS stub — no PTY support on iPadOS (in-process mksh PTY to be added later)
class MacOSLocalProcessTerminalCoordinator: NSObject, TerminalViewDelegate {
    var terminalView: TerminalView?
    var terminalID: UUID?
    var lastCols: Int = -1
    var lastRows: Int = -1

    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
    func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
    func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String : String]) {}
    func bell(source: SwiftTerm.TerminalView) {}
    func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {}
    func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}

    func start(commandLine: [String]? = nil) {}
}
#endif

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
    
    private func updateTerminalAppearance(_ view: TerminalView) {
        let colorName = colorScheme == .dark ? "Kytos-dark" : "Kytos-light"
        if let url = Bundle.main.url(forResource: colorName, withExtension: "itermcolors") {
            loadITermColors(from: url, into: view)
        }
        
        view.font = settings.nsFont
        
        var effectiveStyle = settings.cursorStyle
        #if os(macOS)
        view.terminal.setCursorStyle(effectiveStyle)
        #endif
        // Note: SwiftTerm's TerminalView doesn't seem to expose a direct `blink` toggle property natively outside macOS cursor abstractions. 
        // We will pass the steady struct to the terminal.
        
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }
    
    func makeUIView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, commandLine: commandLine, paneSessionID: paneSessionID).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateUIView(_ uiView: TerminalView, context: Context) {
        updateTerminalAppearance(uiView)
    }
    
    func makeNSView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, commandLine: commandLine, paneSessionID: paneSessionID).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateNSView(_ nsView: TerminalView, context: Context) {
        updateTerminalAppearance(nsView)
    }
    
    func makeCoordinator() -> MacOSLocalProcessTerminalCoordinator {
        KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, commandLine: commandLine, paneSessionID: paneSessionID).coordinator
    }
}

class KytosTerminalManager {
    static let shared = KytosTerminalManager()

    init() {
        #if os(macOS)
        // Poll at 0.1s to latch whichever TerminalView is currently first responder,
        // covering the case where the user clicks directly on a terminal (AppKit
        // calls makeFirstResponder internally without going through KytosRequestFocus).
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            _ = self?.activeTerminalID  // side-effect: updates lastKnownActiveTerminalID
        }
        #endif
    }
    
    struct ManagedTerminal {
        let view: TerminalView
        let coordinator: MacOSLocalProcessTerminalCoordinator
    }
    
    private var terminals: [UUID: ManagedTerminal] = [:]
    /// Maps terminal UUIDs to their pane session IDs for reconnection after stream drops.
    private var terminalSessionIDs: [UUID: String] = [:]

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
        #if os(macOS)
        guard let firstResponder = NSApplication.shared.keyWindow?.firstResponder as? TerminalView else { return nil }
        let found = terminals.first(where: { $0.value.view === firstResponder })?.key
        if let found { lastKnownActiveTerminalID = found }
        return found
        #else
        return nil
        #endif
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
        #if os(macOS)
        let coordinator: MacOSLocalProcessTerminalCoordinator = paneSessionID != nil
            ? KytosPaneStreamingCoordinator()
            : MacOSLocalProcessTerminalCoordinator()
        #else
        let coordinator = MacOSLocalProcessTerminalCoordinator()
        #endif
        coordinator.terminalID = id
        
        let terminal = TerminalView(frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        #if os(macOS)
        terminal.autoresizingMask = [.width, .height]
        terminal.setContentHuggingPriority(.defaultLow, for: .horizontal)
        terminal.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        #else
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        terminal.setContentHuggingPriority(.defaultLow, for: .horizontal)
        terminal.setContentHuggingPriority(.defaultLow, for: .vertical)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        terminal.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        #endif
        
        let colorName = colorScheme == .dark ? "Kytos-dark" : "Kytos-light"
        if let url = Bundle.main.url(forResource: colorName, withExtension: "itermcolors") {
            loadITermColors(from: url, into: terminal)
        }
        
        #if os(macOS)
        terminal.nativeBackgroundColor = .clear
        terminal.layer?.backgroundColor = NSColor.clear.cgColor
        terminal.layer?.isOpaque = false
        #else
        terminal.nativeBackgroundColor = .clear
        terminal.isOpaque = false
        #endif
        
        coordinator.terminalView = terminal
        terminal.terminalDelegate = coordinator
        #if os(macOS)
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
        #else
        coordinator.start(commandLine: commandLine)
        #endif
        
        #if os(macOS)
        // Listen for internal routing to become first responder
        NotificationCenter.default.addObserver(forName: NSNotification.Name("KytosRequestFocus"), object: nil, queue: .main) { [weak terminal] notification in
            guard let terminal = terminal,
                  let requestedID = notification.object as? UUID,
                  requestedID == coordinator.terminalID else { return }
            let hasWindow = terminal.window != nil
            let isFirstResponder = terminal.window?.firstResponder === terminal
            kLog("[KytosDebug][Focus] KytosRequestFocus for \(requestedID.uuidString.prefix(8)) — hasWindow=\(hasWindow), isFirstResponder=\(isFirstResponder)")
            if hasWindow {
                terminal.window?.makeFirstResponder(terminal)
                KytosTerminalManager.shared.recordFocus(id: requestedID)
                kLog("[KytosDebug][Focus]   → makeFirstResponder called, now firstResponder=\(terminal.window?.firstResponder === terminal)")
            } else {
                kLog("[KytosDebug][Focus]   → NO WINDOW, cannot focus")
            }
        }

        // Focus when loaded — retry if the terminal isn't in a window yet
        let termIDForLog = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak terminal] in
            guard let terminal = terminal else {
                kLog("[KytosDebug][Focus] Initial focus for \(termIDForLog.uuidString.prefix(8)) — terminal deallocated")
                return
            }
            let hasWindow = terminal.window != nil
            kLog("[KytosDebug][Focus] Initial focus for \(termIDForLog.uuidString.prefix(8)) — hasWindow=\(hasWindow)")
            if let window = terminal.window {
                window.makeFirstResponder(terminal)
                KytosTerminalManager.shared.recordFocus(id: termIDForLog)
                kLog("[KytosDebug][Focus]   → makeFirstResponder called, now firstResponder=\(window.firstResponder === terminal)")
            } else {
                kLog("[KytosDebug][Focus]   → NO WINDOW at 0.15s, retrying at 0.35s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminal] in
                    guard let terminal = terminal else { return }
                    let hasWindow2 = terminal.window != nil
                    kLog("[KytosDebug][Focus] Retry focus for \(termIDForLog.uuidString.prefix(8)) — hasWindow=\(hasWindow2)")
                    if let window = terminal.window {
                        window.makeFirstResponder(terminal)
                        KytosTerminalManager.shared.recordFocus(id: termIDForLog)
                        kLog("[KytosDebug][Focus]   → retry makeFirstResponder, now firstResponder=\(window.firstResponder === terminal)")
                    } else {
                        kLog("[KytosDebug][Focus]   → STILL NO WINDOW at 0.35s!")
                    }
                }
            }
        }
        #endif
        
        let managed = ManagedTerminal(view: terminal, coordinator: coordinator)
        terminals[id] = managed
        return managed
    }
    
    func getExistingTerminal(id: UUID) -> ManagedTerminal? {
        return terminals[id]
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

    var body: some View {
        #if os(macOS)
        Group {
            if paneInitDone {
                PaneWorkspaceTerminalRepresentable(
                    terminalID: terminalID,
                    commandLine: commandLine,
                    paneSessionID: resolvedSessionID,
                    colorScheme: colorScheme,
                    settings: settings
                )
                .padding(.horizontal, settings.horizontalMargin)
                .background(Color.clear)
                .focusable()
                .focused($isFocused)
                .focusedValue(\.kytosFocusedTerminalID, isFocused ? terminalID : nil)
                .onTapGesture {
                    isFocused = true
                    NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: terminalID)
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
        #else
        PaneWorkspaceTerminalRepresentable(
            terminalID: terminalID,
            commandLine: commandLine,
            paneSessionID: nil,
            colorScheme: colorScheme,
            settings: settings
        )
        .background(Color.clear)
        .focusable()
        .focused($isFocused)
        .focusedValue(\.kytosFocusedTerminalID, isFocused ? terminalID : nil)
        .onTapGesture {
            isFocused = true
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: terminalID)
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
        #endif
    }

    #if os(macOS)
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
            // Persist the session ID (and command line if it was nil) back into the layout tree.
            if case .terminal(let id, let cmd, nil) = layout {
                layout = .terminal(id: id, commandLine: cmd ?? cmdLine, paneSessionID: sid)
                KytosAppModel.shared.save()
            }
        }
        paneInitDone = true
    }
    #endif
    
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
        #if os(macOS)
        if let oldTerminal = KytosTerminalManager.shared.getExistingTerminal(id: terminalID)?.view,
           let window = oldTerminal.window {
            kLog("[KytosDebug][Split] Resigning focus on old terminal \(terminalID.uuidString.prefix(8))")
            window.makeFirstResponder(nil)
        }
        #endif
        // Request focus on the new pane after the view hierarchy updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            kLog("[KytosDebug][Split] Requesting focus for new pane \(newID.uuidString.prefix(8))")
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: newID)
        }
    }
}

struct PaneLayoutTreeView: View {
    @Binding var layout: PaneLayoutTree
    
    var body: some View {
        switch layout {
        case .terminal(let id, let commandLine, let sessionID):
            PaneWorkspaceTerminalView(terminalID: id, commandLine: commandLine, paneSessionID: sessionID, layout: $layout)
                .id(id)  // Preserve @State across layout mutations (e.g. paneSessionID written back)
        case .split(let axis, _, _):
            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneLayoutTreeView(layout: Binding(
                        get: {
                            if case .split(_, let l, _) = layout { return l }
                            return layout
                        },
                        set: { updateLeft(to: $0) }
                    ))
                    Divider()
                    PaneLayoutTreeView(layout: Binding(
                        get: {
                            if case .split(_, _, let r) = layout { return r }
                            return layout
                        },
                        set: { updateRight(to: $0) }
                    ))
                }
            } else {
                VStack(spacing: 0) {
                    PaneLayoutTreeView(layout: Binding(
                        get: {
                            if case .split(_, let l, _) = layout { return l }
                            return layout
                        },
                        set: { updateLeft(to: $0) }
                    ))
                    Divider()
                    PaneLayoutTreeView(layout: Binding(
                        get: {
                            if case .split(_, _, let r) = layout { return r }
                            return layout
                        },
                        set: { updateRight(to: $0) }
                    ))
                }
            }
        }
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

struct PaneWorkspaceView: View {
    @Environment(KytosWorkspace.self) private var workspace

    var body: some View {
        @Bindable var workspaceBindable = workspace

        let _ = kLog("[KytosDebug][PaneWorkspaceView] body — session=\(workspaceBindable.session.name)")

        PaneLayoutTreeView(layout: $workspaceBindable.session.layout)
            .id(workspaceBindable.session.id)
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
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
                    #if os(macOS)
                    // Destroy the pane session if one is attached to this leaf.
                    if case .terminal(_, _, let sid?) = rootLayout.find(id: id) {
                        DispatchQueue.global(qos: .background).async {
                            try? KytosPaneClient.shared.destroySession(id: sid)
                        }
                    }
                    #endif
                    if let newLayout = rootLayout.removing(id: id) {
                        workspaceBindable.session.layout = newLayout
                        // Focus the nearest remaining pane so CMD+W doesn't accidentally close the window.
                        #if os(macOS)
                        if let focusID = newLayout.firstLeafID() {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: focusID)
                            }
                        }
                        #endif
                    } else {
                        #if os(macOS)
                        NSApplication.shared.keyWindow?.performClose(nil)
                        #endif
                    }
                }
            }
    }
}

import Foundation

private let kLogPath = "/tmp/kytos-debug.log"
private let kLogLock = NSLock()

func kLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
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
        #if os(macOS)
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
            KytosTerminalManager.shared.disconnectAll()
            KytosAppModel.shared.save()
        }

        // SIGTERM handler — willTerminateNotification doesn't fire for signals
        signal(SIGTERM) { _ in
            KytosTerminalManager.shared.disconnectAll()
            KytosAppModel.shared.save()
            _exit(0)
        }
        #endif
    }
    
    var body: some Scene {
        #if os(macOS)
        mainWindowGroup
            .commands {
                KytosWorkspaceCommands()
                KelyphosCommands()
            }
        Settings {
            KytosSettingsWindowView(shellState: settingsShellState)
        }
        #else
        mainWindowGroup
            .commands {
                KytosWorkspaceCommands()
            }
        #endif
    }
    
    private var mainWindowGroup: some Scene {
        #if os(macOS)
        WindowGroup("Kytos", id: "main", for: UUID.self) { $windowID in
            KytosWindowView(windowID: $windowID, appModel: appModel)
        }
        #else
        WindowGroup("Kytos") {
            let workspace = appModel.workspace(for: UUID())
            
            KelyphosShellView(
                state: settingsShellState,
                configuration: KelyphosShellConfiguration(
                    navigatorTabs: KytosNavigatorTab.allCases,
                    inspectorTabs: KytosInspectorTab.allCases,
                    utilityTabs: KytosUtilityTab.allCases,
                    detail: { 
                        PaneWorkspaceView()
                    }
                )
            )
            .environment(workspace)
        }
        #endif
    }
}

#if os(macOS)
struct KytosWindowView: View {
    @Binding var windowID: UUID?
    @State private var stableID: UUID
    /// Nil until onAppear fires — prevents workspace creation during SwiftUI's speculative view evaluation.
    @State private var workspace: KytosWorkspace?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var shellState: KelyphosShellState

    var appModel: KytosAppModel

    init(windowID: Binding<UUID?>, appModel: KytosAppModel) {
        self._windowID = windowID
        let resolvedID = windowID.wrappedValue ?? UUID()
        self._stableID = State(initialValue: resolvedID)
        self.appModel = appModel
        let state = KelyphosShellState(persistencePrefix: "me.jwintz.kytos.\(resolvedID.uuidString.prefix(8))")
        state.navigatorVisible = false
        state.utilityAreaVisible = false
        self._shellState = State(initialValue: state)
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
            kLog("[KytosDebug][WindowView] onAppear — windowID=\(windowID?.uuidString.prefix(8) ?? "nil"), stableID=\(stableID.uuidString.prefix(8))")
            kLog("[KytosDebug][WindowView] workspace: session=\(workspace?.session.name ?? "nil"), totalWorkspaces=\(appModel.windows.count)")
            if windowID == nil {
                windowID = stableID
                kLog("[KytosDebug][WindowView] Assigned windowID = stableID (\(stableID.uuidString.prefix(8)))")
            }
            // Remove workspace when the NSWindow actually closes (not just SwiftUI re-renders).
            let id = stableID
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
                guard let window = notification.object as? NSWindow,
                      !( window is NSPanel),
                      appModel.windowToID[ObjectIdentifier(window)] == id else { return }
                kLog("[KytosDebug][WindowView] NSWindow.willClose — removing workspace for \(id.uuidString.prefix(8))")
                appModel.windows.removeValue(forKey: id)
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
            shellState.title = "Kytos"
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
            state: shellState,
            configuration: KelyphosShellConfiguration(
                navigatorTabs: KytosNavigatorTab.allCases,
                inspectorTabs: KytosInspectorTab.allCases,
                utilityTabs: KytosUtilityTab.allCases,
                detail: {
                    PaneWorkspaceView()
                }
            )
        )
        .environment(workspace)
        .focusedSceneValue(\.kytosFocusedWindowID, stableID)
        .background { WindowRegistrar(windowID: stableID) }
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
}
#endif

// MARK: - Window → UUID registrar

/// Zero-size background view that registers an NSWindow with KytosAppModel
/// so tab group structure can be snapshotted at quit time.
#if os(macOS)
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
#endif

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
