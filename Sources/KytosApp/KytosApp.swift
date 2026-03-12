import SwiftUI
import KelyphosKit

enum KytosNavigatorTab: String, KelyphosPanel {
    case sessions = "Sessions"

    nonisolated var id: String { rawValue }
    nonisolated var title: String { rawValue }
    nonisolated var systemImage: String {
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

    nonisolated var id: String { rawValue }
    nonisolated var title: String { rawValue }
    nonisolated var systemImage: String {
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
    nonisolated var id: String { "" }
    nonisolated var title: String { "" }
    nonisolated var systemImage: String { "" }
    var body: some View { EmptyView() }
}

// MARK: - Terminal View (wraps KytosTerminalRepresentable)

import AppKit

struct FocusedTerminalIDKey: FocusedValueKey {
    typealias Value = UUID
}

extension FocusedValues {
    var kytosFocusedTerminalID: UUID? {
        get { self[FocusedTerminalIDKey.self] }
        set { self[FocusedTerminalIDKey.self] = newValue }
    }
}

struct TerminalView: View {
    let terminalID: UUID
    var initialPwd: String?
    @State private var settings = KytosSettings.shared

    // Progress bar state
    @State private var progressState: UInt32 = 0
    @State private var progressPercent: Int8 = -1

    var body: some View {
        ZStack(alignment: .bottom) {
            KytosTerminalRepresentable(terminalID: terminalID, initialPwd: initialPwd)
                .padding(.horizontal, settings.horizontalMargin)
                .background(Color.clear)
            
            if progressState != 0 || progressPercent >= 0 {
                KytosProgressBar(state: progressState, progress: progressPercent)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyProgressReport"))) { notif in
            guard let view = notif.object as? KytosGhosttyView,
                  view.paneID == terminalID else { return }
            if let state = notif.userInfo?["state"] as? UInt32 {
                progressState = state
            }
            if let pcnt = notif.userInfo?["progress"] as? Int8 {
                progressPercent = pcnt
            }
        }
    }
}

// MARK: - Workspace View

struct PaneWorkspaceView: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var searchState = KytosSearchState()
    @State private var settings = KytosSettings.shared
    @State private var splitTreeSize: CGSize = .zero

    var body: some View {
        @Bindable var ws = workspace

        ZStack(alignment: .topTrailing) {
            KytosSplitTreeView(
                tree: workspace.splitTree,
                focusedPaneID: workspace.focusedPaneID,
                onFocusPane: { paneID in
                    workspace.focusedPaneID = paneID
                }
            )
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .overlay {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { splitTreeSize = geo.size }
                        .onChange(of: geo.size) { _, newSize in
                            splitTreeSize = newSize
                            kLog("[SplitTree] size updated: \(newSize)")
                        }
                }
                .allowsHitTesting(false)
            }

            // Search bar overlay
            KytosSearchBar(state: searchState)
                .padding(.trailing, settings.horizontalMargin)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttySetTitle"))) { notif in
            guard let title = notif.userInfo?["title"] as? String, !title.isEmpty else { return }
            if let sourceView = notif.object as? KytosGhosttyView,
               let paneID = sourceView.paneID {
                workspace.splitTree.updateTitle(title, for: paneID)
            } else {
                let targetID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
                workspace.splitTree.updateTitle(title, for: targetID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyPwd"))) { notif in
            guard let pwd = notif.userInfo?["pwd"] as? String else { return }
            if let sourceView = notif.object as? KytosGhosttyView,
               let paneID = sourceView.paneID {
                workspace.splitTree.updatePwd(pwd, for: paneID)
            } else {
                let targetID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
                workspace.splitTree.updatePwd(pwd, for: targetID)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyNewSplit"))) { notif in
            guard let direction = notif.userInfo?["direction"] as? KytosSplitDirection else { return }
            let targetPaneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
            let newPane = KytosPane()
            workspace.splitTree.split(at: targetPaneID, direction: direction, newPane: newPane)
            workspace.focusedPaneID = newPane.id
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyGotoSplit"))) { notif in
            guard let currentID = workspace.focusedPaneID else { return }
            let panes = workspace.splitTree.allPanes
            guard panes.count > 1 else { return }
            guard let idx = panes.firstIndex(where: { $0.id == currentID }) else { return }

            // Extract direction — try UInt32 first (raw enum value), then Int
            let rawDir: UInt32
            if let r = notif.userInfo?["direction"] as? UInt32 {
                rawDir = r
            } else if let r = notif.userInfo?["direction"] as? Int {
                rawDir = UInt32(r)
            } else {
                kLog("[GotoSplit] No direction in notification")
                return
            }

            kLog("[GotoSplit] rawDir=\(rawDir) LEFT=\(GHOSTTY_GOTO_SPLIT_LEFT.rawValue) RIGHT=\(GHOSTTY_GOTO_SPLIT_RIGHT.rawValue) UP=\(GHOSTTY_GOTO_SPLIT_UP.rawValue) DOWN=\(GHOSTTY_GOTO_SPLIT_DOWN.rawValue) NEXT=\(GHOSTTY_GOTO_SPLIT_NEXT.rawValue) PREV=\(GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue)")

            // Map ghostty direction to spatial or sequential
            let spatialDir: KytosSplitTree.SpatialDirection?
            let forward: Bool?
            switch rawDir {
            case GHOSTTY_GOTO_SPLIT_LEFT.rawValue:  spatialDir = .left;  forward = nil
            case GHOSTTY_GOTO_SPLIT_RIGHT.rawValue: spatialDir = .right; forward = nil
            case GHOSTTY_GOTO_SPLIT_UP.rawValue:    spatialDir = .up;    forward = nil
            case GHOSTTY_GOTO_SPLIT_DOWN.rawValue:  spatialDir = .down;  forward = nil
            case GHOSTTY_GOTO_SPLIT_NEXT.rawValue:  spatialDir = nil;    forward = true
            case GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue: spatialDir = nil; forward = false
            default:
                // Fallback: treat as sequential next
                kLog("[GotoSplit] Unknown direction \(rawDir), falling back to next")
                let nextIdx = (idx + 1) % panes.count
                workspace.focusedPaneID = panes[nextIdx].id
                return
            }

            if let spatialDir {
                let bounds = CGRect(origin: .zero, size: splitTreeSize)
                let slots = workspace.splitTree.spatialSlots(in: bounds)
                kLog("[GotoSplit] spatial=\(spatialDir) bounds=\(bounds) slots=\(slots.map { "\($0.paneID.uuidString.prefix(4)):\($0.bounds)" })")
                if let nextID = workspace.splitTree.geometricNeighbor(from: currentID, direction: spatialDir, in: bounds) {
                    kLog("[GotoSplit] → neighbor \(nextID.uuidString.prefix(4))")
                    workspace.focusedPaneID = nextID
                } else {
                    // Fallback to sequential if geometric lookup fails (e.g. no neighbor in that direction)
                    let nextIdx: Int
                    switch spatialDir {
                    case .right, .down: nextIdx = (idx + 1) % panes.count
                    case .left, .up:    nextIdx = (idx - 1 + panes.count) % panes.count
                    }
                    workspace.focusedPaneID = panes[nextIdx].id
                }
            } else if let forward {
                let nextIdx: Int
                if forward {
                    nextIdx = (idx + 1) % panes.count
                } else {
                    nextIdx = (idx - 1 + panes.count) % panes.count
                }
                workspace.focusedPaneID = panes[nextIdx].id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyEqualizeSplits"))) { _ in
            workspace.splitTree.equalize()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyCloseSurface"))) { _ in
            guard let focusedID = workspace.focusedPaneID else { return }
            // Don't close the last pane — close the window instead
            guard workspace.splitTree.isSplit else {
                NSApplication.shared.keyWindow?.performClose(nil)
                return
            }
            if let newFocusID = workspace.splitTree.remove(paneID: focusedID) {
                workspace.focusedPaneID = newFocusID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttySearchTotal"))) { notif in
            if let total = notif.userInfo?["total"] as? Int {
                searchState.totalMatches = max(0, total)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttySearchSelected"))) { notif in
            if let selected = notif.userInfo?["selected"] as? Int {
                searchState.selectedMatch = max(0, selected)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyStartSearch"))) { _ in
            searchState.isVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyFocusChanged"))) { notif in
            if let paneID = notif.userInfo?["paneID"] as? UUID {
                workspace.focusedPaneID = paneID
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosSearchNext"))) { _ in
            guard searchState.isVisible else { return }
            searchState.searchNext()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosSearchPrevious"))) { _ in
            guard searchState.isVisible else { return }
            searchState.searchPrevious()
        }
    }
}

// MARK: - Logging

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
func kLog(_ msg: @autoclosure () -> String) {}
#endif

// MARK: - App Entry Point

import GhosttyKit

@main
struct KytosApp: App {
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var appModel = KytosAppModel.shared
    @State private var settingsShellState: KelyphosShellState = {
        KelyphosShellState(persistencePrefix: "me.jwintz.kytos")
    }()
    @Environment(\.openWindow) private var openWindow

    init() {
        // Activate app
        DispatchQueue.main.async { NSApplication.shared.activate() }

        // Enable native macOS window tabbing
        NSWindow.allowsAutomaticWindowTabbing = true

        // Initialize ghostty app singleton
        _ = KytosGhosttyApp.shared

        // Keyboard shortcuts — Cmd+W close current split, font size
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.keyCode {
                case 13: // Cmd+W — close current split pane (or window if last pane)
                    NotificationCenter.default.post(
                        name: NSNotification.Name("KytosGhosttyCloseSurface"),
                        object: nil
                    )
                    return nil
                case 3: // Cmd+F — toggle scrollback search
                    NotificationCenter.default.post(
                        name: NSNotification.Name("KytosGhosttyStartSearch"),
                        object: nil
                    )
                    return nil
                case 5: // Cmd+G — next search match
                    NotificationCenter.default.post(
                        name: NSNotification.Name("KytosSearchNext"),
                        object: nil
                    )
                    return nil
                default:
                    break
                }
            }
            if flags == [.command, .shift] {
                switch event.keyCode {
                case 5: // Shift+Cmd+G — previous search match
                    NotificationCenter.default.post(
                        name: NSNotification.Name("KytosSearchPrevious"),
                        object: nil
                    )
                    return nil
                default:
                    break
                }
            }
            return event
        }

        // Save state on quit
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { _ in
            KytosAppModel.shared.isTerminating = true
            KytosAppModel.shared.save()
        }

        signal(SIGTERM) { _ in
            DispatchQueue.main.async {
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

// MARK: - Window View

struct KytosWindowView: View {
    @Binding var windowID: UUID?
    @State private var stableID: UUID
    @State private var workspace: KytosWorkspace?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.kelyphosKeybindingRegistry) private var registry
    @State private var windowShellState: KelyphosShellState
    var appModel: KytosAppModel

    init(windowID: Binding<UUID?>, appModel: KytosAppModel) {
        self._windowID = windowID
        let resolvedID = windowID.wrappedValue ?? UUID()
        self._stableID = State(initialValue: resolvedID)
        self.appModel = appModel
        self._windowShellState = State(initialValue: KelyphosShellState(
            persistencePrefix: "me.jwintz.kytos",
            panelPrefix: "me.jwintz.kytos.tmp"
        ))
    }

    var body: some View {
        ZStack {
            if let ws = workspace {
                windowContent(workspace: ws)
            }
        }
        .onAppear {
            if workspace == nil {
                workspace = appModel.workspace(for: stableID)
            }
            if let ws = workspace {
                let stablePrefix = "me.jwintz.kytos.session.\(ws.session.id.uuidString)"
                windowShellState = KelyphosShellState(
                    persistencePrefix: "me.jwintz.kytos",
                    panelPrefix: stablePrefix
                )
            }
            if windowID == nil { windowID = stableID }

            // Remove workspace when NSWindow closes
            let id = stableID
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: nil, queue: .main
            ) { notification in
                guard !appModel.isTerminating else { return }
                guard let window = notification.object as? NSWindow,
                      !(window is NSPanel),
                      appModel.windowToID[ObjectIdentifier(window)] == id else { return }
                appModel.windows.removeValue(forKey: id)
                appModel.save()
            }

            // Restore unclaimed windows
            if !appModel.hasRestoredWindows {
                appModel.hasRestoredWindows = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    let unclaimed = appModel.windows.filter { !appModel.isWindowClaimed($0.key) }
                    for (savedID, _) in unclaimed {
                        openWindow(id: "main", value: savedID)
                    }
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
                                    anchor.addTabbedWindow(window, ordered: .above)
                                }
                                anchor.makeKeyAndOrderFront(nil)
                            }
                        }
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    appModel.pruneOrphanedWorkspaces()
                }
            }

            if let ws = workspace {
                updateToolbar(workspace: ws)
            }
            registry.register(category: "Workspace", label: "Close Pane", shortcut: "⌘W")
            registry.register(category: "Workspace", label: "New Window", shortcut: "⌘N")
            registry.register(category: "Workspace", label: "New Tab", shortcut: "⌘T")
            registry.register(category: "Workspace", label: "Split Horizontal", shortcut: "⌘D")
            registry.register(category: "Workspace", label: "Split Vertical", shortcut: "⇧⌘D")
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
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttySetTitle"))) { notif in
            guard let sourceView = notif.object as? KytosGhosttyView,
                  let paneID = sourceView.paneID else { return }
            let focusedID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
            guard paneID == focusedID else { return }
            let title = notif.userInfo?["title"] as? String ?? ""
            kLog("[Toolbar] SET_TITLE for focused pane: '\(title)'")
            windowShellState.title = title.isEmpty ? "Kytos" : title
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyPwd"))) { notif in
            guard let sourceView = notif.object as? KytosGhosttyView,
                  let paneID = sourceView.paneID else { return }
            let focusedID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
            guard paneID == focusedID else { return }
            let pwd = notif.userInfo?["pwd"] as? String ?? ""
            kLog("[Toolbar] PWD for focused pane: '\(pwd)'")
            windowShellState.subtitle = pwd.isEmpty ? "" : abbreviatePath(pwd)
        }
        .onChange(of: workspace.focusedPaneID) { _, _ in
            updateToolbar(workspace: workspace)
        }
        .onChange(of: windowShellState.navigatorVisible) { _, _ in
            windowShellState.savePanelState()
        }
        .onChange(of: windowShellState.inspectorVisible) { _, _ in
            windowShellState.savePanelState()
        }
        .onChange(of: windowShellState.utilityAreaVisible) { _, _ in
            windowShellState.savePanelState()
        }
    }

    private func updateToolbar(workspace: KytosWorkspace) {
        let id = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        if let pane = workspace.splitTree.findPane(id) {
            let newTitle = pane.title.isEmpty ? "Kytos" : pane.title
            let newSubtitle = pane.pwd.isEmpty ? "" : abbreviatePath(pane.pwd)
            kLog("[Toolbar] updateToolbar: pane=\(id.uuidString.prefix(8)) title='\(pane.title)' pwd='\(pane.pwd)' → title='\(newTitle)' subtitle='\(newSubtitle)'")
            windowShellState.title = newTitle
            windowShellState.subtitle = newSubtitle
        } else {
            kLog("[Toolbar] updateToolbar: pane \(id.uuidString.prefix(8)) NOT FOUND")
        }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

/// Zero-size background view that registers an NSWindow with KytosAppModel.
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

// MARK: - Commands

struct KytosWorkspaceCommands: Commands {
    @FocusedValue(\.kytosFocusedWindowID) var focusedWindowID
    @Environment(\.openWindow) var openWindow

    var body: some Commands {
        CommandMenu("Workspace") {
            Button("New Window") {
                openWindow(id: "main", value: UUID())
            }
            .keyboardShortcut("n", modifiers: .command)
        }
    }
}
