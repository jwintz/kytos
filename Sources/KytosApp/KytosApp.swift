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
    @State private var settings = KytosSettings.shared

    var body: some View {
        KytosTerminalRepresentable(terminalID: terminalID)
            .padding(.horizontal, settings.horizontalMargin)
            .background(Color.clear)
    }
}

// MARK: - Workspace View

struct PaneWorkspaceView: View {
    @Environment(KytosWorkspace.self) private var workspace

    var body: some View {
        TerminalView(terminalID: workspace.session.id)
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttySetTitle"))) { notif in
                if let title = notif.object as? String, !title.isEmpty {
                    workspace.session.name = title
                }
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

        // Keyboard shortcuts — Cmd+W close, font size
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == .command {
                switch event.keyCode {
                case 13: // Cmd+W — close window/tab
                    NSApplication.shared.keyWindow?.performClose(nil)
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

            windowShellState.title = "Kytos"
            registry.register(category: "Workspace", label: "Close Pane", shortcut: "⌘W")
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
