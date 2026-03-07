import SwiftUI
#if os(macOS)
import AppKit
#endif
import UniformTypeIdentifiers
import WidgetKit

public enum PaneLayoutTree: Codable, Hashable {
    case terminal(id: UUID, commandLine: [String]? = nil, paneSessionID: String? = nil)
    indirect case split(axis: Axis, left: PaneLayoutTree, right: PaneLayoutTree)

    public enum Axis: String, Codable, Hashable {
        case horizontal
        case vertical
    }

    public enum MoveDirection {
        case left, right, up, down
    }

    public enum PathDirection {
        case left, right
    }

    public func path(to id: UUID) -> [PathDirection]? {
        switch self {
        case .terminal(let tid, _, _):
            if tid == id { return [] }
            return nil
        case .split(_, let left, let right):
            if let leftPath = left.path(to: id) {
                return [.left] + leftPath
            }
            if let rightPath = right.path(to: id) {
                return [.right] + rightPath
            }
            return nil
        }
    }

    public func neighbor(of id: UUID, direction: MoveDirection) -> UUID? {
        guard let p = self.path(to: id) else { return nil }

        var targetSubtree: PaneLayoutTree? = nil
        var remainingPath = p
        var ancestorNodes = [PaneLayoutTree]()
        var node = self
        ancestorNodes.append(node)

        for step in remainingPath {
            if case .split(_, let left, let right) = node {
                node = (step == .left) ? left : right
                ancestorNodes.append(node)
            }
        }

        var i = p.count - 1
        while i >= 0 {
            let parent = ancestorNodes[i]
            let stepTaken = p[i]
            if case .split(let axis, let left, let right) = parent {
                // macOS SwiftUI HStack is horizontal (left/right split)
                if direction == .left && axis == .horizontal && stepTaken == .right {
                    targetSubtree = left
                    break
                }
                if direction == .right && axis == .horizontal && stepTaken == .left {
                    targetSubtree = right
                    break
                }
                // VStack is vertical (up/down split), left=top, right=bottom
                if direction == .up && axis == .vertical && stepTaken == .right {
                    targetSubtree = left
                    break
                }
                if direction == .down && axis == .vertical && stepTaken == .left {
                    targetSubtree = right
                    break
                }
            }
            i -= 1
        }

        guard let subtree = targetSubtree else { return nil }

        var curr = subtree
        while true {
            switch curr {
            case .terminal(let tid, _, _):
                return tid
            case .split(let axis, let left, let right):
                // If moving left into an HStack, land on the right child.
                if direction == .left && axis == .horizontal {
                    curr = right
                } else if direction == .right && axis == .horizontal {
                    curr = left
                } else if direction == .up && axis == .vertical {
                    curr = right
                } else if direction == .down && axis == .vertical {
                    curr = left
                } else {
                    curr = left
                }
            }
        }
    }

    public func removing(id: UUID) -> PaneLayoutTree? {
        switch self {
        case .terminal(let tid, _, _):
            return tid == id ? nil : self
        case .split(let axis, let left, let right):
            let newLeft = left.removing(id: id)
            let newRight = right.removing(id: id)

            if newLeft == nil && newRight == nil { return nil }
            if newLeft == nil { return newRight }
            if newRight == nil { return newLeft }

            return .split(axis: axis, left: newLeft!, right: newRight!)
        }
    }

    #if os(macOS)
    /// Returns the terminal leaf with the given ID, or nil if not found.
    func find(id: UUID) -> PaneLayoutTree? {
        switch self {
        case .terminal(let tid, _, _):
            return tid == id ? self : nil
        case .split(_, let left, let right):
            return left.find(id: id) ?? right.find(id: id)
        }
    }

    /// Returns the UUID of the first terminal leaf found (depth-first left).
    func firstLeafID() -> UUID? {
        switch self {
        case .terminal(let id, _, _): return id
        case .split(_, let left, _): return left.firstLeafID()
        }
    }
    func allPaneSessionIDs() -> [String] {
        switch self {
        case .terminal(_, _, let sid):
            return sid.map { [$0] } ?? []
        case .split(_, let left, let right):
            return left.allPaneSessionIDs() + right.allPaneSessionIDs()
        }
    }

    /// Looks up the paneSessionID for a terminal UUID in this tree.
    func sessionID(for terminalID: UUID) -> String? {
        switch self {
        case .terminal(let id, _, let sid):
            return id == terminalID ? sid : nil
        case .split(_, let left, let right):
            return left.sessionID(for: terminalID) ?? right.sessionID(for: terminalID)
        }
    }

    /// Returns all (terminalID, paneSessionID?) leaf pairs.
    func allTerminalLeaves() -> [(id: UUID, commandLine: [String]?, sessionID: String?)] {
        switch self {
        case .terminal(let id, let commandLine, let sid):
            return [(id: id, commandLine: commandLine, sessionID: sid)]
        case .split(_, let left, let right):
            return left.allTerminalLeaves() + right.allTerminalLeaves()
        }
    }

    /// Number of terminal leaves in this subtree.
    var leafCount: Int {
        switch self {
        case .terminal: return 1
        case .split(_, let left, let right): return left.leafCount + right.leafCount
        }
    }

    /// Returns a copy of the tree where any terminal leaf whose paneSessionID is not
    /// in `liveSessions` has its paneSessionID cleared (set to nil), so the view will
    /// create a fresh session on next appear.
    func clearingDeadSessions(_ liveSessions: Set<String>) -> PaneLayoutTree {
        switch self {
        case .terminal(let id, let commandLine, let sessionID):
            let isLive = sessionID.map { liveSessions.contains($0) } ?? false
            return .terminal(id: id, commandLine: commandLine, paneSessionID: isLive ? sessionID : nil)
        case .split(let axis, let left, let right):
            return .split(
                axis: axis,
                left: left.clearingDeadSessions(liveSessions),
                right: right.clearingDeadSessions(liveSessions)
            )
        }
    }

    /// Clears duplicate paneSessionIDs: if a session ID has already been seen,
    /// the leaf's ID is cleared so a fresh session is created.
    func deduplicatingSessions(_ seen: inout Set<String>) -> PaneLayoutTree {
        switch self {
        case .terminal(let id, let commandLine, let sessionID):
            if let sid = sessionID {
                if seen.contains(sid) {
                    kLog("[KytosDebug][AppModel] dedup — clearing duplicate session \(sid) from terminal \(id.uuidString.prefix(8))")
                    return .terminal(id: id, commandLine: commandLine, paneSessionID: nil)
                }
                seen.insert(sid)
            }
            return self
        case .split(let axis, let left, let right):
            return .split(
                axis: axis,
                left: left.deduplicatingSessions(&seen),
                right: right.deduplicatingSessions(&seen)
            )
        }
    }
    #endif
}

public struct KytosSession: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var layout: PaneLayoutTree

    public init(id: UUID = UUID(), name: String = "Session", layout: PaneLayoutTree) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

/// One macOS window/tab. Each workspace holds a single session with its split pane layout.
@Observable
public final class KytosWorkspace: Codable {
    public var session: KytosSession

    public init(session: KytosSession) {
        self.session = session
    }

    public static func defaultWorkspace() -> KytosWorkspace {
        let initialTerminal = PaneLayoutTree.terminal(id: UUID())
        let defaultSession = KytosSession(name: "Terminal", layout: initialTerminal)
        return KytosWorkspace(session: defaultSession)
    }

    // MARK: - Codable
    enum CodingKeys: String, CodingKey {
        case session
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decode(KytosSession.self, forKey: .session)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(session, forKey: .session)
    }
}

@Observable
public final class KytosAppModel {
    public static let shared = KytosAppModel()

    public var windows: [UUID: KytosWorkspace] = [:]

    #if os(macOS)
    /// Set after `reconcileSessionsOnLaunch` completes. Gates `initPaneSession`
    /// to prevent using stale session IDs before dedup/clearing runs.
    @ObservationIgnored public private(set) var reconciliationDone = false
    private let reconciliationLock = NSLock()
    private var reconciliationContinuations: [CheckedContinuation<Void, Never>] = []

    /// Waits until session reconciliation has completed (dedup + dead session clearing).
    public func waitForReconciliation() async {
        reconciliationLock.lock()
        if reconciliationDone {
            reconciliationLock.unlock()
            return
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            reconciliationContinuations.append(cont)
            reconciliationLock.unlock()
        }
    }

    private func signalReconciliationDone() {
        reconciliationLock.lock()
        reconciliationDone = true
        let pending = reconciliationContinuations
        reconciliationContinuations = []
        reconciliationLock.unlock()
        for cont in pending {
            cont.resume()
        }
    }
    #endif

    private init() {
        load()
        startWidgetRefreshTimer()
    }

    // MARK: - Widget Refresh Timer

    @ObservationIgnored private var widgetRefreshTimer: Timer?

    private func startWidgetRefreshTimer() {
        widgetRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.writeWidgetSnapshot()
        }
    }

    /// Set of windowIDs that have been claimed by live windows in this session.
    @ObservationIgnored private var claimedWindowIDs: Set<UUID> = []
    @ObservationIgnored public var hasRestoredWindows = false

    /// Set by the willTerminate handler to prevent NSWindow.willClose from
    /// removing workspaces and overwriting the saved state during shutdown.
    @ObservationIgnored public var isTerminating = false

    // MARK: - Window → UUID mapping (populated at runtime by WindowRegistrar)

    /// Maps each live NSWindow's identity to its workspace UUID.
    /// Used at quit time to snapshot tab group structure.
    @ObservationIgnored public var windowToID: [ObjectIdentifier: UUID] = [:]

    #if os(macOS)
    public func registerWindow(_ window: NSWindow, for id: UUID) {
        windowToID[ObjectIdentifier(window)] = id
    }
    #endif

    public func workspace(for windowID: UUID) -> KytosWorkspace {
        if let existing = windows[windowID] {
            claimedWindowIDs.insert(windowID)
            return existing
        }
        kLog("[KytosDebug][AppModel] workspace(for: \(windowID.uuidString.prefix(8))) — no exact match, existing=\(windows.count), claimed=\(claimedWindowIDs.count)")
        // Find the first unclaimed workspace from a previous session to remap
        let unclaimed = windows.filter { !claimedWindowIDs.contains($0.key) }
        if let (oldKey, existing) = unclaimed.first {
            kLog("[KytosDebug][AppModel]   → remapping \(oldKey.uuidString.prefix(8)) → \(windowID.uuidString.prefix(8)), session=\(existing.session.name)")
            // Migrate panel-visibility UserDefaults from old window UUID to new one
            Self.migratePanelDefaults(from: oldKey, to: windowID)
            // Batch remove+insert to trigger didSet only once
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

    /// Removes orphaned workspaces that no live window has claimed.
    /// Call after all windows have appeared.
    public func pruneOrphanedWorkspaces() {
        let orphanedKeys = windows.keys.filter { !claimedWindowIDs.contains($0) }
        guard !orphanedKeys.isEmpty else { return }
        kLog("[KytosDebug][AppModel] Pruning \(orphanedKeys.count) orphaned workspace(s), keeping \(claimedWindowIDs.count)")
        // Batch: build new dict to trigger didSet only once
        var pruned = windows
        for key in orphanedKeys {
            pruned.removeValue(forKey: key)
        }
        windows = pruned
    }

    public func save() {
        do {
            let data = try JSONEncoder().encode(windows)
            UserDefaults.standard.set(data, forKey: "KytosAppModel_Windows_v5")
            kLog("[KytosDebug][AppModel] save() — \(windows.count) window(s), \(data.count) bytes")
        } catch {
            kLog("[KytosDebug][AppModel] save() FAILED: \(error)")
        }
        saveTabGroups()
        writeWidgetSnapshot()
    }

    private func writeWidgetSnapshot() {
        let windowList = windows.values.map { workspace -> KytosWidgetWindow in
            let leaves = workspace.session.layout.allTerminalLeaves()
            let terminals = leaves.map { leaf -> KytosWidgetTerminal in
                let process = KytosTerminalManager.shared.foregroundProcessName(for: leaf.id)
                    ?? leaf.commandLine?.first
                    ?? "zsh"
                return KytosWidgetTerminal(id: leaf.id, process: process)
            }
            return KytosWidgetWindow(id: workspace.session.id, name: workspace.session.name, terminals: terminals)
        }
        let snapshot = KytosWidgetSnapshot(date: .now, windows: windowList)
        KytosWidgetSnapshot.write(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Copies panel-visibility UserDefaults from one window UUID to another so that
    /// navigator/inspector state survives window-ID remapping across launches.
    private static func migratePanelDefaults(from oldID: UUID, to newID: UUID) {
        let defaults = UserDefaults.standard
        let oldPrefix = "me.jwintz.kytos.window.\(oldID.uuidString)"
        let newPrefix = "me.jwintz.kytos.window.\(newID.uuidString)"
        let suffixes = [".panel.navigatorVisible", ".panel.inspectorVisible", ".panel.utilityVisible"]
        for suffix in suffixes {
            let oldKey = oldPrefix + suffix
            let newKey = newPrefix + suffix
            if defaults.object(forKey: oldKey) != nil {
                defaults.set(defaults.bool(forKey: oldKey), forKey: newKey)
                defaults.removeObject(forKey: oldKey)
            }
        }
        kLog("[KytosDebug][AppModel] Migrated panel defaults \(oldID.uuidString.prefix(8)) → \(newID.uuidString.prefix(8))")
    }

    /// Reads the live NSWindowTabGroup state and persists which UUIDs were tabbed together.
    private func saveTabGroups() {
        #if os(macOS)
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
            kLog("[KytosDebug][AppModel] saveTabGroups() — \(groups.count) group(s)")
        }
        #endif
    }

    /// Returns saved tab groups from the previous session, or an empty array.
    public func loadTabGroups() -> [[UUID]] {
        guard let data = UserDefaults.standard.data(forKey: "KytosAppModel_TabGroups_v1"),
              let groups = try? JSONDecoder().decode([[UUID]].self, from: data) else { return [] }
        return groups
    }

    private func load() {
        kLog("[KytosDebug][AppModel] load()")
        guard let data = UserDefaults.standard.data(forKey: "KytosAppModel_Windows_v5") else {
            kLog("[KytosDebug][AppModel] load() — no saved data")
            #if os(macOS)
            signalReconciliationDone()
            #endif
            return
        }
        do {
            let decoded = try JSONDecoder().decode([UUID: KytosWorkspace].self, from: data)
            kLog("[KytosDebug][AppModel] load() — \(data.count) bytes → \(decoded.count) workspace(s)")
            for (key, ws) in decoded {
                kLog("[KytosDebug][AppModel]   window \(key.uuidString.prefix(8)): session=\(ws.session.name)")
            }
            self.windows = decoded
        } catch {
            kLog("[KytosDebug][AppModel] load() DECODE FAILED: \(error)")
        }
        #if os(macOS)
        // Reconcile on a background thread to avoid blocking the main thread with
        // socket I/O during app launch (server startup can take up to 2.5s).
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            reconcileSessionsOnLaunch()
        }
        #endif
    }

    #if os(macOS)
    /// Cross-references persisted paneSessionIDs with the live pane server.
    /// Sessions that no longer exist (server restarted or timed out) have their IDs cleared
    /// so they'll be recreated fresh when the terminal view appears.
    /// Called on a background thread; mutations dispatched back to main.
    private func reconcileSessionsOnLaunch() {
        // Collect all persisted session IDs to see if we even need the server.
        let allPersistedIDs = windows.values.flatMap {
            $0.session.layout.allPaneSessionIDs()
        }
        guard !allPersistedIDs.isEmpty else {
            kLog("[KytosDebug][AppModel] reconcile — no persisted session IDs, skipping")
            signalReconciliationDone()
            return
        }

        let liveSessions: Set<String>
        do {
            // First try: server may already be running from the previous app session.
            let list = try KytosPaneClient.shared.listSessions()
            liveSessions = Set(list.filter { $0.isRunning }.map { $0.id })
            kLog("[KytosDebug][AppModel] reconcile — \(liveSessions.count) live pane session(s)")
        } catch {
            // Server not running yet — start it and retry once.
            kLog("[KytosDebug][AppModel] reconcile — server not reachable (\(error)), starting and retrying")
            do {
                let list = try KytosPaneClient.shared.listSessionsWithStart()
                liveSessions = Set(list.filter { $0.isRunning }.map { $0.id })
                kLog("[KytosDebug][AppModel] reconcile (retry) — \(liveSessions.count) live pane session(s)")
            } catch {
                // Truly unreachable — clear stale IDs.
                liveSessions = []
                kLog("[KytosDebug][AppModel] reconcile — pane server unreachable after retry, clearing all sessionIDs: \(error)")
            }
        }
        DispatchQueue.main.async { [self] in
            // Deduplicate: if multiple leaves reference the same session ID, keep only
            // the first and clear the rest so they create fresh sessions.
            var seenSessionIDs = Set<String>()
            for workspace in windows.values {
                workspace.session.layout = workspace.session.layout
                    .clearingDeadSessions(liveSessions)
                    .deduplicatingSessions(&seenSessionIDs)
            }
            signalReconciliationDone()
        }
    }
    #endif
}
