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
    case settings = "Settings"
    
    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String {
        switch self {
        case .process: return "info.circle"
        case .settings: return "gear"
        }
    }
    
    var body: some View {
        switch self {
        case .process:
            Text("No active process selected")
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .settings:
            KytosSettingsView()
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

enum KytosUtilityTab: String, KelyphosPanel {
    case logs = "System Logs"
    
    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String { "list.bullet.rectangle" }
    
    var body: some View {
        Text("Kytos Logging Ready")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct KytosSessionsSidebar: View {
    @Environment(KytosWorkspace.self) private var workspace

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
        }
        .listStyle(.sidebar)
    }
}

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

class MacOSLocalProcessTerminalCoordinator: NSObject, TerminalViewDelegate, LocalProcessDelegate {
    
    // MARK: - LocalProcessDelegate Requirements
    func processTerminated(_ source: SwiftTerm.LocalProcess, exitCode: Int32?) {
        print("[KytosDebug] Shell Terminated with code: \(String(describing: exitCode))")
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
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16(f.width), ws_ypixel: UInt16(f.height))
    }
    
    // MARK: - TerminalViewDelegate Requirements
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        guard newCols != lastCols || newRows != lastRows else { return }
        lastCols = newCols
        lastRows = newRows
        print("[KytosDebug] TerminalView sizeChanged: cols=\(newCols), rows=\(newRows)")
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
    private var lastCols: Int = -1
    private var lastRows: Int = -1
    
    func start(with shellChoice: String? = nil) {
        let bundledMksh = Bundle.main.url(forAuxiliaryExecutable: "mksh_bin")?.path ?? Bundle.main.bundlePath + "/Contents/MacOS/mksh_bin"
        
        let shell: String
        let args: [String]
        
        let userChoice = shellChoice ?? KytosSettings.shared.shellChoice.rawValue
        
        var environment = ProcessInfo.processInfo.environment
        if userChoice == KytosSettings.ShellChoice.embeddedMksh.rawValue {
            shell = bundledMksh
            args = ["-l"]
            
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
        } else {
            shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            args = ["-l"]
        }
        
        print("[KytosDebug] Starting shell: \(shell)")
        
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["SHELL"] = shell
        let envArray = environment.map { "\($0.key)=\($0.value)" }
        process.startProcess(executable: shell, args: args, environment: envArray)
        print("[KytosDebug] Shell launched calling startProcess")
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
    let shellChoice: String?
    let colorScheme: ColorScheme
    let settings: KytosSettings
    
    private func updateTerminalAppearance(_ view: TerminalView) {
        let colorName = colorScheme == .dark ? "Kytos-dark" : "Kytos-light"
        if let url = Bundle.main.url(forResource: colorName, withExtension: "itermcolors") {
            loadITermColors(from: url, into: view)
        }
        
        view.font = settings.nsFont
        
        var effectiveStyle = settings.cursorStyle
        view.terminal.setCursorStyle(effectiveStyle)
        // Note: SwiftTerm's TerminalView doesn't seem to expose a direct `blink` toggle property natively outside macOS cursor abstractions. 
        // We will pass the steady struct to the terminal.
        
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }
    
    func makeUIView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, shellChoice: shellChoice).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateUIView(_ uiView: TerminalView, context: Context) {
        updateTerminalAppearance(uiView)
    }
    
    func makeNSView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, shellChoice: shellChoice).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateNSView(_ nsView: TerminalView, context: Context) {
        updateTerminalAppearance(nsView)
    }
    
    func makeCoordinator() -> MacOSLocalProcessTerminalCoordinator {
        KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme, shellChoice: shellChoice).coordinator
    }
}

class KytosTerminalManager {
    static let shared = KytosTerminalManager()
    
    struct ManagedTerminal {
        let view: TerminalView
        let coordinator: MacOSLocalProcessTerminalCoordinator
    }
    
    private var terminals: [UUID: ManagedTerminal] = [:]
    
    var activeTerminalID: UUID? {
        #if os(macOS)
        let responder = NSApplication.shared.keyWindow?.firstResponder
        print("[KytosDebug] Evaluating activeTerminalID. FirstResponder: \(String(describing: responder))")
        guard let firstResponder = responder as? TerminalView else { 
            print("[KytosDebug] FirstResponder is not a TerminalView")
            return nil 
        }
        let matchingKey = terminals.first(where: { $0.value.view === firstResponder })?.key
        print("[KytosDebug] Found matching active terminal UUID: \(String(describing: matchingKey))")
        return matchingKey
        #else
        return nil
        #endif
    }
    
    func getOrCreateTerminal(id: UUID, colorScheme: ColorScheme, shellChoice: String? = nil) -> ManagedTerminal {
        if let existing = terminals[id] {
            return existing
        }
        let coordinator = MacOSLocalProcessTerminalCoordinator()
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
        coordinator.start(with: shellChoice)
        
        // Listen for internal routing to become first responder
        NotificationCenter.default.addObserver(forName: NSNotification.Name("KytosRequestFocus"), object: nil, queue: .main) { [weak terminal] notification in
            guard let terminal = terminal,
                  let requestedID = notification.object as? UUID,
                  requestedID == coordinator.terminalID else { return }
            let hasWindow = terminal.window != nil
            let isFirstResponder = terminal.window?.firstResponder === terminal
            print("[KytosDebug][Focus] KytosRequestFocus for \(requestedID.uuidString.prefix(8)) — hasWindow=\(hasWindow), isFirstResponder=\(isFirstResponder)")
            if hasWindow {
                terminal.window?.makeFirstResponder(terminal)
                print("[KytosDebug][Focus]   → makeFirstResponder called, now firstResponder=\(terminal.window?.firstResponder === terminal)")
            } else {
                print("[KytosDebug][Focus]   → NO WINDOW, cannot focus")
            }
        }

        // Focus when loaded — retry if the terminal isn't in a window yet
        let termIDForLog = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak terminal] in
            guard let terminal = terminal else {
                print("[KytosDebug][Focus] Initial focus for \(termIDForLog.uuidString.prefix(8)) — terminal deallocated")
                return
            }
            let hasWindow = terminal.window != nil
            print("[KytosDebug][Focus] Initial focus for \(termIDForLog.uuidString.prefix(8)) — hasWindow=\(hasWindow)")
            if let window = terminal.window {
                window.makeFirstResponder(terminal)
                print("[KytosDebug][Focus]   → makeFirstResponder called, now firstResponder=\(window.firstResponder === terminal)")
            } else {
                print("[KytosDebug][Focus]   → NO WINDOW at 0.15s, retrying at 0.35s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak terminal] in
                    guard let terminal = terminal else { return }
                    let hasWindow2 = terminal.window != nil
                    print("[KytosDebug][Focus] Retry focus for \(termIDForLog.uuidString.prefix(8)) — hasWindow=\(hasWindow2)")
                    if let window = terminal.window {
                        window.makeFirstResponder(terminal)
                        print("[KytosDebug][Focus]   → retry makeFirstResponder, now firstResponder=\(window.firstResponder === terminal)")
                    } else {
                        print("[KytosDebug][Focus]   → STILL NO WINDOW at 0.35s!")
                    }
                }
            }
        }
        
        let managed = ManagedTerminal(view: terminal, coordinator: coordinator)
        terminals[id] = managed
        return managed
    }
    
    func getExistingTerminal(id: UUID) -> ManagedTerminal? {
        return terminals[id]
    }

    func removeTerminal(id: UUID) {
        terminals.removeValue(forKey: id)
    }
}

struct PaneWorkspaceTerminalView: View {
    let terminalID: UUID
    let shellChoice: String?
    @Binding var layout: PaneLayoutTree
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = KytosSettings.shared
    
    var body: some View {
        PaneWorkspaceTerminalRepresentable(terminalID: terminalID, shellChoice: shellChoice, colorScheme: colorScheme, settings: settings)
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
    }
    
    private func split(axis: PaneLayoutTree.Axis) {
        let newID = UUID()
        print("[KytosDebug][Split] axis=\(axis), existingID=\(terminalID.uuidString.prefix(8)), newID=\(newID.uuidString.prefix(8))")
        let newTree = PaneLayoutTree.split(
            axis: axis,
            left: .terminal(id: terminalID, shell: shellChoice),
            right: .terminal(id: newID, shell: KytosSettings.shared.shellChoice.rawValue)
        )
        layout = newTree
        // Resign focus on the old terminal so its cursor becomes hollow
        #if os(macOS)
        if let oldTerminal = KytosTerminalManager.shared.getExistingTerminal(id: terminalID)?.view,
           let window = oldTerminal.window {
            print("[KytosDebug][Split] Resigning focus on old terminal \(terminalID.uuidString.prefix(8))")
            window.makeFirstResponder(nil)
        }
        #endif
        // Request focus on the new pane after the view hierarchy updates
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            print("[KytosDebug][Split] Requesting focus for new pane \(newID.uuidString.prefix(8))")
            NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: newID)
        }
    }
}

struct PaneLayoutTreeView: View {
    @Binding var layout: PaneLayoutTree
    
    var body: some View {
        switch layout {
        case .terminal(let id, let shell):
            PaneWorkspaceTerminalView(terminalID: id, shellChoice: shell, layout: $layout)
        case .split(let axis, let left, let right):
            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneLayoutTreeView(layout: Binding(
                        get: { left },
                        set: { updateLeft(to: $0) }
                    ))
                    Divider()
                    PaneLayoutTreeView(layout: Binding(
                        get: { right },
                        set: { updateRight(to: $0) }
                    ))
                }
            } else {
                VStack(spacing: 0) {
                    PaneLayoutTreeView(layout: Binding(
                        get: { left },
                        set: { updateLeft(to: $0) }
                    ))
                    Divider()
                    PaneLayoutTreeView(layout: Binding(
                        get: { right },
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

        let _ = print("[KytosDebug][PaneWorkspaceView] body — session=\(workspaceBindable.session.name)")

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
                    if let newLayout = rootLayout.removing(id: id) {
                        workspaceBindable.session.layout = newLayout
                    } else {
                        #if os(macOS)
                        NSApplication.shared.keyWindow?.performClose(nil)
                        #endif
                    }
                }
            }
    }
}

@main
struct KytosApp: App {
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var appModel = KytosAppModel.shared
    @State private var shellState: KelyphosShellState = {
        let state = KelyphosShellState(persistencePrefix: "me.jwintz.kytos")
        state.navigatorVisible = false
        state.utilityAreaVisible = false
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
                    print("[KytosDebug][KeyMonitor] Cmd+W intercepted — activeTerminalID=\(KytosTerminalManager.shared.activeTerminalID?.uuidString.prefix(8) ?? "nil")")
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
            print("[KytosDebug][App] willTerminate — saving state")
            KytosAppModel.shared.save()
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
            KelyphosSettingsView(state: shellState)
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
            KytosWindowView(windowID: $windowID, appModel: appModel, shellState: shellState)
        }
        #else
        WindowGroup("Kytos") {
            let workspace = appModel.workspace(for: UUID())
            
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

    var appModel: KytosAppModel
    var shellState: KelyphosShellState

    init(windowID: Binding<UUID?>, appModel: KytosAppModel, shellState: KelyphosShellState) {
        self._windowID = windowID
        let resolvedID = windowID.wrappedValue ?? UUID()
        self._stableID = State(initialValue: resolvedID)
        self.appModel = appModel
        self.shellState = shellState
        print("[KytosDebug][WindowView] init — windowID=\(windowID.wrappedValue?.uuidString.prefix(8) ?? "nil"), stableID=\(resolvedID.uuidString.prefix(8))")
    }

    var body: some View {
        ZStack {
            if let ws = workspace {
                windowContent(workspace: ws)
            }
        }
        .onDisappear {
            // Window was closed — remove its workspace so it's not restored on next launch
            print("[KytosDebug][WindowView] onDisappear — removing workspace for \(stableID.uuidString.prefix(8))")
            appModel.windows.removeValue(forKey: stableID)
        }
        .onAppear {
            // Create workspace only here — onAppear fires for real windows, not speculative views
            if workspace == nil {
                workspace = appModel.workspace(for: stableID)
            }
            print("[KytosDebug][WindowView] onAppear — windowID=\(windowID?.uuidString.prefix(8) ?? "nil"), stableID=\(stableID.uuidString.prefix(8))")
            print("[KytosDebug][WindowView] workspace: session=\(workspace?.session.name ?? "nil"), totalWorkspaces=\(appModel.windows.count)")
            if windowID == nil {
                windowID = stableID
                print("[KytosDebug][WindowView] Assigned windowID = stableID (\(stableID.uuidString.prefix(8)))")
            }
            if !appModel.hasRestoredWindows {
                appModel.hasRestoredWindows = true
                print("[KytosDebug][Restore] First window appeared — scheduling restore check in 0.5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let unclaimed = appModel.windows.filter { !appModel.isWindowClaimed($0.key) }
                    print("[KytosDebug][Restore] Unclaimed workspaces: \(unclaimed.count) (total=\(appModel.windows.count), claimed=\(unclaimed.count == 0 ? appModel.windows.count : appModel.windows.count - unclaimed.count))")
                    for (savedID, ws) in unclaimed {
                        print("[KytosDebug][Restore] Opening window for savedID=\(savedID.uuidString.prefix(8)), session=\(ws.session.name)")
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
                                    print("[KytosDebug][Restore] Re-grouping \(appModel.windowToID[ObjectIdentifier(window)]?.uuidString.prefix(8) ?? "?") into tab group")
                                    anchor.addTabbedWindow(window, ordered: .above)
                                }
                                anchor.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    print("[KytosDebug][Restore] Pruning at 3s — claimed=\(appModel.windows.filter { appModel.isWindowClaimed($0.key) }.count)")
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

            print("[KytosDebug][WindowView:\(stableID.uuidString.prefix(8))] KelyphosCommandInvoked: '\(label)'")

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

            print("[KytosDebug][WindowView:\(stableID.uuidString.prefix(8))] KytosWorkspaceAction: '\(action)'")

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
