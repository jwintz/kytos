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
        List {
            ForEach(workspace.tabs) { tab in
                Section(header: Text(tab.name)) {
                    ForEach(tab.sessions) { session in
                        NavigationLink(value: session.id) {
                            Label(session.name, systemImage: "terminal")
                        }
                    }
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
        print("[KytosDebug] Received \(slice.count) bytes")
        terminalView?.feed(byteArray: slice)
    }
    func getWindowSize() -> winsize {
        guard let terminal = terminalView?.terminal else { return winsize() }
        let f: CGRect = terminalView!.frame
        return winsize(ws_row: UInt16(terminal.rows), ws_col: UInt16(terminal.cols), ws_xpixel: UInt16(f.width), ws_ypixel: UInt16(f.height))
    }
    
    // MARK: - TerminalViewDelegate Requirements
    func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
        print("[KytosDebug] TerminalView sizeChanged: cols=\(newCols), rows=\(newRows), frame=\(source.frame)")
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
    
    func start() {
        let bundledMksh = Bundle.main.url(forAuxiliaryExecutable: "mksh_bin")?.path ?? Bundle.main.bundlePath + "/Contents/MacOS/mksh_bin"
        
        let shell: String
        let args: [String]
        
        switch KytosSettings.shared.shellChoice {
        case .systemShell:
            shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            args = ["-l"]
        case .embeddedMksh:
            shell = bundledMksh
            args = ["-l"]
        }
        
        print("[KytosDebug] Starting shell: \(shell)")
        
        var environment = ProcessInfo.processInfo.environment
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
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateUIView(_ uiView: TerminalView, context: Context) {
        updateTerminalAppearance(uiView)
    }
    
    func makeNSView(context: Context) -> TerminalView {
        let terminal = KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme).view
        updateTerminalAppearance(terminal)
        return terminal
    }
    
    func updateNSView(_ nsView: TerminalView, context: Context) {
        updateTerminalAppearance(nsView)
    }
    
    func makeCoordinator() -> MacOSLocalProcessTerminalCoordinator {
        KytosTerminalManager.shared.getOrCreateTerminal(id: terminalID, colorScheme: colorScheme).coordinator
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
    
    func getOrCreateTerminal(id: UUID, colorScheme: ColorScheme) -> ManagedTerminal {
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
        coordinator.start()
        
        // Listen for internal routing to become first responder
        NotificationCenter.default.addObserver(forName: NSNotification.Name("KytosRequestFocus"), object: nil, queue: .main) { [weak terminal] notification in
            guard let terminal = terminal,
                  let requestedID = notification.object as? UUID,
                  requestedID == coordinator.terminalID else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        
        // Focus when loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminal.window?.makeFirstResponder(terminal)
        }
        
        let managed = ManagedTerminal(view: terminal, coordinator: coordinator)
        terminals[id] = managed
        return managed
    }
    
    func removeTerminal(id: UUID) {
        terminals.removeValue(forKey: id)
    }
}

struct PaneWorkspaceTerminalView: View {
    let terminalID: UUID
    @Binding var layout: PaneLayoutTree
    @FocusState private var isFocused: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var settings = KytosSettings.shared
    
    var body: some View {
        PaneWorkspaceTerminalRepresentable(terminalID: terminalID, colorScheme: colorScheme, settings: settings)
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
        let newTree = PaneLayoutTree.split(
            axis: axis,
            left: .terminal(id: terminalID),
            right: .terminal(id: UUID())
        )
        layout = newTree
    }
}

struct PaneLayoutTreeView: View {
    @Binding var layout: PaneLayoutTree
    
    var body: some View {
        switch layout {
        case .terminal(let id):
            PaneWorkspaceTerminalView(terminalID: id, layout: $layout)
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
        if let tabID = workspace.selectedTabID,
           let tabIndex = workspace.tabs.firstIndex(where: { $0.id == tabID }),
           let sessionID = workspace.tabs[tabIndex].selectedSessionID ?? workspace.tabs[tabIndex].sessions.first?.id,
           let sessionIndex = workspace.tabs[tabIndex].sessions.firstIndex(where: { $0.id == sessionID }) {
            
            @Bindable var workspaceBindable = workspace
            PaneLayoutTreeView(layout: $workspaceBindable.tabs[tabIndex].sessions[sessionIndex].layout)
                .frame(maxWidth: .infinity)
                .containerRelativeFrame(.vertical)
                .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosWorkspaceAction"))) { notification in
                    guard let userInfo = notification.userInfo,
                          let action = userInfo["action"] as? String,
                          let id = userInfo["id"] as? UUID else { return }
                          
                    print("[KytosDebug] PaneWorkspaceView received action: \(action) for pane: \(id)")
                    
                    let rootLayout = workspaceBindable.tabs[tabIndex].sessions[sessionIndex].layout
                    print("[KytosDebug] Current Tree Layout Size: \(rootLayout)")
                    
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
                            print("[KytosDebug] Computing neighbor for direction: \(dir)")
                            if let nextID = rootLayout.neighbor(of: id, direction: dir) {
                                print("[KytosDebug] Neighbor found: \(nextID). Requesting focus.")
                                NotificationCenter.default.post(name: NSNotification.Name("KytosRequestFocus"), object: nextID)
                            } else {
                                print("[KytosDebug] No neighbor found in direction: \(dir)")
                            }
                        }
                    } else if action == "closePane" {
                        print("[KytosDebug] Removing pane: \(id)")
                        if let newLayout = rootLayout.removing(id: id) {
                            print("[KytosDebug] Updating tree after removal")
                            workspaceBindable.tabs[tabIndex].sessions[sessionIndex].layout = newLayout
                        } else {
                            print("[KytosDebug] Tree could not be resolved or was last pane. Closing window.")
                            #if os(macOS)
                            NSApplication.shared.keyWindow?.performClose(nil)
                            #endif
                        }
                    }
                }
            
        } else {
            Text("No Session Selected")
                .foregroundColor(.secondary)
        }
    }
}

@main
struct KytosApp: App {
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var workspace = KytosWorkspace.load()
    @State private var shellState = KelyphosShellState(persistencePrefix: "com.kytos")
    
    var body: some Scene {
        mainWindowGroup
            .commands {
                KytosWorkspaceCommands()
            }

        #if os(macOS)
        Settings {
            KelyphosSettingsView(state: shellState)
        }
        #endif
    }
    
    private var mainWindowGroup: some Scene {
        WindowGroup("Kytos") {
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
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KelyphosCommandInvoked"))) { notification in
                guard let userInfo = notification.userInfo,
                      let label = userInfo["label"] as? String else { return }
                
                if label == "Close Pane" {
                    let activeID = KytosTerminalManager.shared.activeTerminalID
                    print("[KytosDebug] Key monitor invoked: Close Pane for \(String(describing: activeID))")
                    if let id = activeID {
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
            .onAppear {
                shellState.title = "Kytos"
                registry.register(category: "Workspace", label: "Split Horizontal", shortcut: "⌘D")
                registry.register(category: "Workspace", label: "Split Vertical", shortcut: "⇧⌘D")
                registry.register(category: "Workspace", label: "Close Pane", shortcut: "⌘W")
                registry.register(category: "Workspace", label: "Navigate Left", shortcut: "⌘⌥←")
                registry.register(category: "Workspace", label: "Navigate Right", shortcut: "⌘⌥→")
                registry.register(category: "Workspace", label: "Navigate Up", shortcut: "⌘⌥↑")
                registry.register(category: "Workspace", label: "Navigate Down", shortcut: "⌘⌥↓")
                
                #if os(macOS)
                NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    // keyCode 13 is the "W" key
                    if flags == .command && event.keyCode == 13 {
                        if let id = KytosTerminalManager.shared.activeTerminalID {
                            print("[KytosDebug] Global Event Monitor intercepted CMD+W for pane: \(id)")
                            NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "closePane", "id": id])
                            return nil // prevent the window from closing natively
                        }
                    }
                    return event
                }
                #endif
            }
        }
        #if os(macOS)
        .commands {
            KelyphosCommands(state: shellState)
        }
        #endif
    }
}

struct KytosWorkspaceCommands: Commands {
    @FocusedValue(\.kytosFocusedTerminalID) var focusedID
    
    private var activeID: UUID? {
        let terminalID = KytosTerminalManager.shared.activeTerminalID ?? focusedID
        print("[KytosDebug] KytosWorkspaceCommands evaluated activeID: \(String(describing: terminalID)) (focusedID: \(String(describing: focusedID)))")
        return terminalID
    }
    
    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Split Horizontal") {
                print("[KytosDebug] Command invoked: Split Horizontal")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitHorizontal", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            
            Button("Split Vertical") {
                print("[KytosDebug] Command invoked: Split Vertical")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitVertical", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Close Pane") {
                print("[KytosDebug] Command invoked: Close Pane")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "closePane", "id": id])
                }
            }
            // Temporarily removing .keyboardShortcut("w") here because macOS forces CMD+W to close the Main Window.
            // A local key monitor will intercept it instead.
            
            Divider()
            
            Button("Navigate Left") {
                print("[KytosDebug] Command invoked: Navigate Left")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navLeft", "id": id])
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            
            Button("Navigate Right") {
                print("[KytosDebug] Command invoked: Navigate Right")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navRight", "id": id])
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            
            Button("Navigate Up") {
                print("[KytosDebug] Command invoked: Navigate Up")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navUp", "id": id])
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            
            Button("Navigate Down") {
                print("[KytosDebug] Command invoked: Navigate Down")
                if let id = activeID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navDown", "id": id])
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
