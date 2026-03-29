// ProcessMonitor.swift — Global singleton for batched process enumeration (KY2-1)
//
// Replaces per-window `.task` polling loops that each called `/bin/ps` independently.
// A single background task runs one `psSnapshot()` + `detectProcessNames()` cycle every
// 30 seconds, then publishes the results for all windows and panels to observe.

import Foundation

@MainActor @Observable
final class ProcessMonitor {
    static let shared = ProcessMonitor()

    /// Latest process-name updates keyed by pane UUID.
    private(set) var processNames: [UUID: String] = [:]

    /// Monotonically increasing counter bumped on each snapshot cycle.
    /// Views observe this to know when fresh data is available.
    private(set) var snapshotVersion: UInt64 = 0

    /// Latest raw ps snapshot — reused by the inspector panel to build its
    /// process tree and system stats without a redundant `/bin/ps` call.
    private(set) var latestSnapshot: [pid_t: KytosProcessUtil.PSEntry] = [:]

    @ObservationIgnored private var pollTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// Perform an immediate out-of-cycle refresh (e.g. on title/pwd change).
    /// Respects a 2-second throttle to avoid redundant calls.
    @ObservationIgnored private var lastPollDate: Date = .distantPast
    @ObservationIgnored private var deferredPollScheduled = false

    func requestRefresh() {
        let elapsed = Date().timeIntervalSince(lastPollDate)
        if elapsed < 2.0 {
            guard !deferredPollScheduled else { return }
            deferredPollScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2.0 - elapsed))
                guard let self else { return }
                self.deferredPollScheduled = false
                await self.poll()
            }
            return
        }
        Task { await poll() }
    }

    private func poll() async {
        lastPollDate = Date()

        // Collect all panes across every workspace
        let allWorkspaces = KytosAppModel.shared.windows.values
        var allPanes: [KytosPane] = []
        for ws in allWorkspaces {
            allPanes.append(contentsOf: ws.splitTree.allPanes)
        }
        let childPids = KytosGhosttyView.childPids

        let result = await Task.detached { () -> ([(UUID, String)], [pid_t: KytosProcessUtil.PSEntry]) in
            let snapshot = KytosProcessUtil.psSnapshot()
            let updates = KytosProcessUtil.detectProcessNames(for: allPanes, knownChildPids: childPids)
            return (updates, snapshot)
        }.value

        // Publish process names
        var names: [UUID: String] = [:]
        for (id, name) in result.0 {
            names[id] = name
        }
        processNames = names
        latestSnapshot = result.1
        snapshotVersion &+= 1

        // Push names into every workspace's split tree + post notification
        for ws in allWorkspaces {
            for (id, name) in result.0 {
                ws.splitTree.updateProcessName(name, for: id)
            }
        }
        NotificationCenter.default.post(
            name: NSNotification.Name("KytosProcessNamesUpdated"),
            object: nil
        )
    }
}
