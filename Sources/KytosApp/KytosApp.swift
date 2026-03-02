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

enum KytosInspectorTab: String, KelyphosPanel {
    case process = "Process Info"
    
    var id: String { rawValue }
    var title: String { rawValue }
    var systemImage: String { "info.circle" }
    
    var body: some View {
        Text("No active process selected")
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        print("[KytosDebug] Starting shell: \(bundledMksh)")
        let shell = bundledMksh // Enforce mksh explicitly, skip environment shell fallback
        let args = ["-l"]
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["SHELL"] = bundledMksh
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
    
    func makeUIView(context: Context) -> TerminalView {
        makeTerminalView(context: context)
    }
    
    func updateUIView(_ uiView: TerminalView, context: Context) {}
    
    func makeNSView(context: Context) -> TerminalView {
        makeTerminalView(context: context)
    }
    
    func updateNSView(_ nsView: TerminalView, context: Context) {}
    
    func makeCoordinator() -> MacOSLocalProcessTerminalCoordinator {
        MacOSLocalProcessTerminalCoordinator()
    }
    
    private func makeTerminalView(context: Context) -> TerminalView {
        context.coordinator.terminalID = terminalID
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
        
        if let url = Bundle.main.url(forResource: "Kytos-dark", withExtension: "itermcolors") {
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
        
        context.coordinator.terminalView = terminal
        terminal.terminalDelegate = context.coordinator
        context.coordinator.start()
        
        // Listen for internal routing to become first responder
        NotificationCenter.default.addObserver(forName: NSNotification.Name("KytosRequestFocus"), object: nil, queue: .main) { [weak terminal] notification in
            guard let terminal = terminal,
                  let requestedID = notification.object as? UUID,
                  requestedID == context.coordinator.terminalID else { return }
            terminal.window?.makeFirstResponder(terminal)
        }
        
        // Focus when loaded
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            terminal.window?.makeFirstResponder(terminal)
        }
        return terminal
    }
}

struct PaneWorkspaceTerminalView: View {
    let terminalID: UUID
    @Binding var layout: PaneLayoutTree
    @FocusState private var isFocused: Bool
    
    var body: some View {
        PaneWorkspaceTerminalRepresentable(terminalID: terminalID)
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
                case "navLeft": navigate(direction: .left)
                case "navRight": navigate(direction: .right)
                case "navUp": navigate(direction: .up)
                case "navDown": navigate(direction: .down)
                default: break
                }
            }
    }
    
    private func navigate(direction: MoveDirection) {
        print("[KytosDebug] Navigation requested: \(direction)")
    }
    
    enum MoveDirection {
        case left, right, up, down
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
            .onAppear {
                shellState.title = "Kytos"
                registry.register(category: "Workspace", label: "Split Horizontal", shortcut: "⌘D")
                registry.register(category: "Workspace", label: "Split Vertical", shortcut: "⇧⌘D")
                registry.register(category: "Workspace", label: "Navigate Left", shortcut: "⌘⌥←")
                registry.register(category: "Workspace", label: "Navigate Right", shortcut: "⌘⌥→")
                registry.register(category: "Workspace", label: "Navigate Up", shortcut: "⌘⌥↑")
                registry.register(category: "Workspace", label: "Navigate Down", shortcut: "⌘⌥↓")
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
    
    var body: some Commands {
        CommandMenu("Workspace") {
            Button("Split Horizontal") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitHorizontal", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: .command)
            
            Button("Split Vertical") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "splitVertical", "id": id])
                }
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            
            Divider()
            
            Button("Navigate Left") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navLeft", "id": id])
                }
            }
            .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            
            Button("Navigate Right") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navRight", "id": id])
                }
            }
            .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
            
            Button("Navigate Up") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navUp", "id": id])
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            
            Button("Navigate Down") {
                if let id = focusedID {
                    NotificationCenter.default.post(name: NSNotification.Name("KytosWorkspaceAction"), object: nil, userInfo: ["action": "navDown", "id": id])
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])
        }
    }
}
