import SwiftUI
import AppKit
import UniformTypeIdentifiers
import WidgetKit

/// A single terminal session — holds a UUID that maps to a ghostty surface.
public struct KytosSession: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

/// One macOS window/tab. Each workspace holds a split tree of panes.
@Observable
public final class KytosWorkspace: Codable {
    public var splitTree: KytosSplitTree
    public var focusedPaneID: UUID?

    /// Backward-compatible computed property — returns the first leaf pane as a session.
    public var session: KytosSession {
        get {
            let pane = splitTree.firstLeaf
            return KytosSession(id: pane.id, name: pane.title)
        }
        set {
            splitTree.updateTitle(newValue.name, for: splitTree.firstLeaf.id)
        }
    }

    public init(splitTree: KytosSplitTree) {
        self.splitTree = splitTree
        self.focusedPaneID = splitTree.firstLeaf.id
    }

    public convenience init(session: KytosSession) {
        let pane = KytosPane(id: session.id, title: session.name)
        self.init(splitTree: KytosSplitTree(pane: pane))
    }

    public static func defaultWorkspace() -> KytosWorkspace {
        KytosWorkspace(session: KytosSession())
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case splitTree, focusedPaneID
        // Legacy key for v6 migration
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let tree = try? container.decode(KytosSplitTree.self, forKey: .splitTree) {
            // v7 format
            self.splitTree = tree
            self.focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
        } else if let session = try? container.decode(KytosSession.self, forKey: .session) {
            // v6 migration: single session → leaf node
            let pane = KytosPane(id: session.id, title: session.name)
            self.splitTree = KytosSplitTree(pane: pane)
            self.focusedPaneID = pane.id
        } else {
            // Fallback
            let pane = KytosPane()
            self.splitTree = KytosSplitTree(pane: pane)
            self.focusedPaneID = pane.id
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(splitTree, forKey: .splitTree)
        try container.encode(focusedPaneID, forKey: .focusedPaneID)
    }
}

@Observable
@MainActor
public final class KytosAppModel {
    public static let shared = KytosAppModel()

    public var windows: [UUID: KytosWorkspace] = [:]

    private init() {
        load()
        startWidgetRefreshTimer()
    }

    // MARK: - Widget Refresh Timer

    @ObservationIgnored private var widgetRefreshTimer: Timer?

    private func startWidgetRefreshTimer() {
        widgetRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.writeWidgetSnapshot()
            }
        }
    }

    /// Set of windowIDs that have been claimed by live windows in this session.
    @ObservationIgnored private var claimedWindowIDs: Set<UUID> = []
    @ObservationIgnored private var restoredWindowIDRemap: [UUID: UUID] = [:]
    @ObservationIgnored private var pendingTabGroups: [[UUID]] = []
    @ObservationIgnored private var tabRestorationRetryScheduled = false
    @ObservationIgnored public var hasRestoredWindows = false

    /// Set by the willTerminate handler to prevent NSWindow.willClose from
    /// removing workspaces and overwriting the saved state during shutdown.
    @ObservationIgnored public var isTerminating = false

    // MARK: - Window → UUID mapping (populated at runtime by WindowRegistrar)

    @ObservationIgnored public var windowToID: [ObjectIdentifier: UUID] = [:]

    public func registerWindow(_ window: NSWindow, for id: UUID) {
        windowToID[ObjectIdentifier(window)] = id
        kLog("[KytosDebug][AppModel] registerWindow(\(id.uuidString.prefix(8))) title='\(window.title)' contentView=\(window.contentView != nil)")
        attemptPendingTabRestoration()
    }

    public func windowID(for window: NSWindow?) -> UUID? {
        guard let window else { return nil }
        return windowToID[ObjectIdentifier(window)]
    }

    public func window(for id: UUID) -> NSWindow? {
        NSApp.windows.first { windowToID[ObjectIdentifier($0)] == id }
    }

    public func workspace(for windowID: UUID) -> KytosWorkspace {
        if let existing = windows[windowID] {
            claimedWindowIDs.insert(windowID)
            kLog("[Restore][AppModel] workspace(for: \(windowID.uuidString.prefix(8))) — exact match, panes=\(existing.splitTree.allPanes.count)")
            return existing
        }
        kLog("[KytosDebug][AppModel] workspace(for: \(windowID.uuidString.prefix(8))) — no exact match")
        let unclaimed = windows.filter { !claimedWindowIDs.contains($0.key) }
        if let (oldKey, existing) = unclaimed.first {
            kLog("[KytosDebug][AppModel]   → remapping \(oldKey.uuidString.prefix(8)) → \(windowID.uuidString.prefix(8))")
            restoredWindowIDRemap[oldKey] = windowID
            Self.migratePanelDefaults(from: oldKey, to: windowID)
            remapPendingTabGroups(from: oldKey, to: windowID)
            var updated = windows
            updated.removeValue(forKey: oldKey)
            updated[windowID] = existing
            windows = updated
            claimedWindowIDs.insert(windowID)
            return existing
        }
        kLog("[KytosDebug][AppModel]   → creating default workspace")
        let newWorkspace = KytosWorkspace.defaultWorkspace()
        windows[windowID] = newWorkspace
        claimedWindowIDs.insert(windowID)
        return newWorkspace
    }

    public func isWindowClaimed(_ windowID: UUID) -> Bool {
        claimedWindowIDs.contains(windowID)
    }

    public func pruneOrphanedWorkspaces() {
        let orphanedKeys = windows.keys.filter { !claimedWindowIDs.contains($0) }
        guard !orphanedKeys.isEmpty else { return }
        var pruned = windows
        for key in orphanedKeys { pruned.removeValue(forKey: key) }
        windows = pruned
    }

    public func save() {
        do {
            let data = try JSONEncoder().encode(windows)
            // Save as v7 (split tree format), keep v6 key for backward migration reads
            UserDefaults.standard.set(data, forKey: "KytosAppModel_Windows_v7")
            kLog("[KytosDebug][AppModel] save() — \(windows.count) window(s)")
        } catch {
            kLog("[KytosDebug][AppModel] save() FAILED: \(error)")
        }
        saveTabGroups()
        writeWidgetSnapshot()
    }

    private func writeWidgetSnapshot() {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path

        let windowList = windows.values.map { workspace -> KytosWidgetWindow in
            let terminals = workspace.splitTree.allPanes.map { pane in
                KytosWidgetTerminal(id: pane.id, process: pane.processName.isEmpty ? "shell" : pane.processName)
            }
            return KytosWidgetWindow(id: workspace.session.id, name: workspace.session.name, terminals: terminals)
        }

        // Build navigator-style pane list for medium widget
        let widgetPanes: [KytosWidgetPane] = windows.values.flatMap { workspace -> [KytosWidgetPane] in
            let focusedID = workspace.focusedPaneID
            return workspace.splitTree.allPanes.map { pane in
                let steps = workspace.splitTree.positionSteps(for: pane.id) ?? []
                let symbols = steps.map(\.sfSymbol)
                var path = pane.pwd
                if path.hasPrefix(homePath) {
                    path = "~" + path.dropFirst(homePath.count)
                }
                return KytosWidgetPane(
                    id: pane.id,
                    processName: pane.processName.isEmpty ? "shell" : pane.processName,
                    path: path,
                    positionSymbols: symbols,
                    isFocused: pane.id == focusedID
                )
            }
        }

        // Build process tree for large widget
        let ourPid = ProcessInfo.processInfo.processIdentifier
        let panes = windows.values.flatMap { $0.splitTree.allPanes }
        let psSnapshot = KytosProcessUtil.psSnapshot()
        let liveShellPIDs = KytosProcessUtil.liveShellPIDs(for: panes, snapshot: psSnapshot)
        let rawTree = KytosProcessInfoView.processTree(
            rootPID: ourPid,
            liveShellPIDs: liveShellPIDs,
            logLabel: "widget",
            includeFullTreeWhenNoLiveShells: false
        )
        let processTree = rawTree.enumerated().map { idx, entry in
            KytosWidgetProcessNode(
                pid: entry.pid,
                command: (entry.command as NSString).lastPathComponent,
                depth: entry.depth,
                rssMB: entry.rssMB,
                cpu: entry.cpu,
                isDeepest: idx == rawTree.count - 1
            )
        }

        let snapshot = KytosWidgetSnapshot(
            date: .now,
            version: UInt64(Date().timeIntervalSince1970 * 1000),
            windows: windowList,
            processTree: processTree,
            panes: widgetPanes
        )
        KytosWidgetSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func migratePanelDefaults(from oldID: UUID, to newID: UUID) {
        let defaults = UserDefaults.standard
        let oldPrefix = "me.jwintz.kytos.window.\(oldID.uuidString)"
        let newPrefix = "me.jwintz.kytos.window.\(newID.uuidString)"
        let suffixes = [".panel.navigatorVisible", ".panel.inspectorVisible", ".panel.utilityVisible"]
        for suffix in suffixes {
            let oldKey = oldPrefix + suffix
            let newKey = newPrefix + suffix
            if defaults.object(forKey: oldKey) != nil {
                let val = defaults.bool(forKey: oldKey)
                kLog("[Restore][AppModel] migratePanelDefaults \(suffix)=\(val) from \(oldID.uuidString.prefix(8)) → \(newID.uuidString.prefix(8))")
                defaults.set(val, forKey: newKey)
                defaults.removeObject(forKey: oldKey)
            }
        }
    }

    private func saveTabGroups() {
        var groups: [[UUID]] = []
        var processed = Set<ObjectIdentifier>()
        for window in NSApp.windows where !(window is NSPanel) && window.contentView != nil {
            let key = ObjectIdentifier(window)
            guard !processed.contains(key) else { continue }
            if let tabGroup = window.tabGroup, tabGroup.windows.count > 1 {
                let groupUUIDs = tabGroup.windows.compactMap { windowToID[ObjectIdentifier($0)] }
                tabGroup.windows.forEach { processed.insert(ObjectIdentifier($0)) }
                if groupUUIDs.count > 1 { groups.append(groupUUIDs) }
            } else {
                processed.insert(key)
            }
        }
        if let data = try? JSONEncoder().encode(groups) {
            UserDefaults.standard.set(data, forKey: "KytosAppModel_TabGroups_v1")
        }
    }

    public func loadTabGroups() -> [[UUID]] {
        guard let data = UserDefaults.standard.data(forKey: "KytosAppModel_TabGroups_v1"),
              let groups = try? JSONDecoder().decode([[UUID]].self, from: data) else { return [] }
        return groups
    }

    public func preparePendingTabRestoration(_ groups: [[UUID]]) {
        pendingTabGroups = groups
            .map { group in group.map { restoredWindowIDRemap[$0] ?? $0 } }
            .filter { $0.count > 1 }
        let summary = pendingTabGroups.map { group in group.map { String($0.uuidString.prefix(8)) } }
        kLog("[KytosDebug][AppModel] preparePendingTabRestoration groups=\(summary)")
        attemptPendingTabRestoration()
    }

    private func remapPendingTabGroups(from oldID: UUID, to newID: UUID) {
        pendingTabGroups = pendingTabGroups.map { group in
            group.map { $0 == oldID ? newID : $0 }
        }
        let summary = pendingTabGroups.map { group in group.map { String($0.uuidString.prefix(8)) } }
        kLog("[KytosDebug][AppModel] remapPendingTabGroups \(oldID.uuidString.prefix(8)) -> \(newID.uuidString.prefix(8)) groups=\(summary)")
    }

    public func attemptPendingTabRestoration(attemptsRemaining: Int = 40) {
        guard !pendingTabGroups.isEmpty else { return }
        let summary = pendingTabGroups.map { group in group.map { String($0.uuidString.prefix(8)) } }
        kLog("[KytosDebug][AppModel] attemptPendingTabRestoration attempts=\(attemptsRemaining) groups=\(summary)")

        var unresolved: [[UUID]] = []
        for group in pendingTabGroups {
            let windows = group.compactMap(window(for:))
                .filter { !($0 is NSPanel) && $0.contentView != nil }
            let resolved = windows.compactMap { windowID(for: $0).map { String($0.uuidString.prefix(8)) } }
            kLog("[KytosDebug][AppModel]   group=\(group.map { String($0.uuidString.prefix(8)) }) resolved=\(resolved)")
            guard windows.count == group.count, let anchor = windows.first else {
                unresolved.append(group)
                continue
            }

            // Check if already tabbed together (native restoration may have handled it)
            if let tabGroup = anchor.tabGroup, tabGroup.windows.count >= group.count {
                let allPresent = windows.allSatisfy { w in tabGroup.windows.contains(where: { $0 === w }) }
                if allPresent {
                    kLog("[KytosDebug][AppModel]   group already tabbed natively, skipping")
                    continue
                }
            }

            // Ensure all windows are visible before tabbing — addTabbedWindow
            // silently fails on windows that haven't been ordered yet.
            for window in windows {
                if !window.isVisible {
                    window.orderFront(nil)
                }
            }

            for window in windows.dropFirst() where window !== anchor {
                if anchor.tabGroup?.windows.contains(where: { $0 === window }) != true {
                    kLog("[KytosDebug][AppModel]   tabbing \(windowID(for: window)?.uuidString.prefix(8) ?? "unknown") into \(windowID(for: anchor)?.uuidString.prefix(8) ?? "unknown")")
                    anchor.addTabbedWindow(window, ordered: .above)
                }
            }
            // Verify tabbing succeeded
            let tabbedCount = anchor.tabGroup?.windows.count ?? 1
            if tabbedCount < group.count {
                kLog("[KytosDebug][AppModel]   tabbing incomplete: expected \(group.count) got \(tabbedCount), will retry")
                unresolved.append(group)
            } else {
                kLog("[KytosDebug][AppModel]   tabbing succeeded: \(tabbedCount) tabs")
            }
            anchor.makeKeyAndOrderFront(nil)
        }

        pendingTabGroups = unresolved
        guard !pendingTabGroups.isEmpty, attemptsRemaining > 0, !tabRestorationRetryScheduled else { return }
        tabRestorationRetryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.tabRestorationRetryScheduled = false
            self.attemptPendingTabRestoration(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func load() {
        // Try v7 first, then fall back to v6
        let key: String
        if UserDefaults.standard.data(forKey: "KytosAppModel_Windows_v7") != nil {
            key = "KytosAppModel_Windows_v7"
        } else {
            key = "KytosAppModel_Windows_v6"
        }
        guard let data = UserDefaults.standard.data(forKey: key) else {
            kLog("[KytosDebug][AppModel] load() — no saved data")
            return
        }
        do {
            let decoded = try JSONDecoder().decode([UUID: KytosWorkspace].self, from: data)
            self.windows = decoded
            kLog("[KytosDebug][AppModel] load() — \(decoded.count) workspace(s) from \(key)")
        } catch {
            kLog("[KytosDebug][AppModel] load() DECODE FAILED: \(error)")
        }
    }
}
