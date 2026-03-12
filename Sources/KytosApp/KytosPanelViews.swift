// KytosPanelViews.swift — navigator sidebar + inspector panels

import SwiftUI
import Foundation
import GhosttyKit

// MARK: - Sessions Sidebar

struct KytosSessionsSidebar: View {
    @Environment(KytosWorkspace.self) private var workspace

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(workspace.splitTree.allPanes, id: \.id) { pane in
                    KytosPaneRowView(pane: pane, workspace: workspace)
                }
            }
            .padding(10)
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
    }
}

private struct KytosPaneRowView: View {
    let pane: KytosPane
    let workspace: KytosWorkspace
    @State private var isHovering = false

    private var isFocused: Bool { workspace.focusedPaneID == pane.id }

    var body: some View {
        HStack(spacing: 8) {
            // Focus indicator
            Circle()
                .fill(isFocused ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(pane.processName.isEmpty ? "shell" : pane.processName)
                    .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                    .lineLimit(1)

                if !pane.pwd.isEmpty {
                    Text(abbreviatePath(pane.pwd))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Position indicator (SF Symbol composition) — trailing side
            if let posSteps = workspace.splitTree.positionSteps(for: pane.id), workspace.splitTree.isSplit {
                HStack(spacing: 1) {
                    ForEach(Array(posSteps.enumerated()), id: \.offset) { _, step in
                        Image(systemName: step.sfSymbol)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            // Close button (visible on hover)
            if isHovering {
                Button {
                    KytosGhosttyView.view(for: pane.id)?.closeSurface()
                    if workspace.splitTree.isSplit {
                        if let newFocusID = workspace.splitTree.remove(paneID: pane.id) {
                            workspace.focusedPaneID = newFocusID
                        }
                    } else {
                        // Last pane — close the window
                        NSApplication.shared.keyWindow?.performClose(nil)
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close pane")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary.opacity(0.5))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.focusedPaneID = pane.id
        }
        .onHover { isHovering = $0 }
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

// MARK: - Process Utilities

import AppKit
import Darwin

/// Shared process detection utilities used by inspector, toolbar, and navigator.
enum KytosProcessUtil {
    /// Parsed process entry from `ps` output.
    struct PSEntry {
        let pid: pid_t
        let ppid: pid_t
        let comm: String
    }

    /// Snapshot of all processes via `ps`. Cached per detection cycle.
    static func psSnapshot() -> [pid_t: PSEntry] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid=,ppid=,comm="]
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [:] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()

        var result: [pid_t: PSEntry] = [:]
        for line in out.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard cols.count >= 3,
                  let pid = pid_t(cols[0]),
                  let ppid = pid_t(cols[1]) else { continue }
            let comm = String(cols[2])
            result[pid] = PSEntry(pid: pid, ppid: ppid, comm: comm)
        }
        return result
    }

    /// Get CWD for a process via `lsof`.
    static func cwdForPid(_ pid: pid_t) -> String? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-a", "-d", "cwd", "-p", String(pid), "-Fn"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()

        // lsof -Fn output: lines starting with 'n' contain the path
        for line in out.components(separatedBy: "\n") {
            if line.hasPrefix("n") && line.count > 1 {
                return String(line.dropFirst())
            }
        }
        return nil
    }

    /// Find all direct child PIDs of a parent process using a ps snapshot.
    static func findAllChildren(of parentPid: pid_t, in snapshot: [pid_t: PSEntry]) -> [pid_t] {
        snapshot.values.filter { $0.ppid == parentPid }.map(\.pid).sorted()
    }

    /// Walk down the process tree to find the deepest single-child descendant.
    static func findDeepestChild(of pid: pid_t, in snapshot: [pid_t: PSEntry]) -> pid_t {
        var current = pid
        for _ in 0..<10 {
            let children = findAllChildren(of: current, in: snapshot)
            guard let child = children.first, children.count == 1 else { break }
            current = child
        }
        return current
    }

    /// Get the process name for a PID from a ps snapshot.
    static func processName(of pid: pid_t, in snapshot: [pid_t: PSEntry]) -> String? {
        guard let entry = snapshot[pid] else { return nil }
        // Extract just the binary name from the full path
        return (entry.comm as NSString).lastPathComponent
    }

    /// Info about a shell process (grandchild of Kytos, child of login).
    struct ShellInfo {
        let shellPid: pid_t
        let cwd: String
    }

    /// Find the shell processes for all panes using a ps snapshot.
    /// Kytos → login → zsh (shell). We match panes to shells by CWD.
    static func findShells(snapshot: [pid_t: PSEntry]) -> [ShellInfo] {
        let ourPid = Foundation.ProcessInfo.processInfo.processIdentifier
        let directChildren = findAllChildren(of: ourPid, in: snapshot)
        kLog("[ProcessUtil] ourPid=\(ourPid) directChildren=\(directChildren)")
        var shells: [ShellInfo] = []
        for child in directChildren {
            let childName = processName(of: child, in: snapshot) ?? "?"
            let grandchildren = findAllChildren(of: child, in: snapshot)
            kLog("[ProcessUtil]   child \(child) (\(childName)) → grandchildren=\(grandchildren)")
            if let shellPid = grandchildren.first {
                let shellName = processName(of: shellPid, in: snapshot) ?? "?"
                let cwd = cwdForPid(shellPid) ?? ""
                kLog("[ProcessUtil]     shell \(shellPid) (\(shellName)) cwd='\(cwd)'")
                shells.append(ShellInfo(shellPid: shellPid, cwd: cwd))
            }
        }
        return shells
    }

    /// Match a shell to a pane by CWD. Returns the shell PID or nil.
    static func matchShell(for pane: KytosPane, from shells: [ShellInfo], excluding used: Set<pid_t>) -> pid_t? {
        guard !pane.pwd.isEmpty else { return nil }
        for shell in shells where !used.contains(shell.shellPid) {
            if shell.cwd == pane.pwd || shell.cwd.hasPrefix(pane.pwd) || pane.pwd.hasPrefix(shell.cwd) {
                return shell.shellPid
            }
        }
        return nil
    }

    /// Detect process names for a list of panes. Returns [(paneID, processName)].
    /// Safe to call from a detached task (no MainActor dependency).
    static func detectProcessNames(for panes: [KytosPane]) -> [(UUID, String)] {
        let snapshot = psSnapshot()
        let shells = findShells(snapshot: snapshot)
        kLog("[ProcessUtil] detectProcessNames: \(panes.count) panes, \(shells.count) shells")

        var usedShells = Set<pid_t>()
        var updates: [(UUID, String)] = []
        for pane in panes {
            var shellPid = matchShell(for: pane, from: shells, excluding: usedShells)
            kLog("[ProcessUtil]   pane \(pane.id.uuidString.prefix(8)) pwd='\(pane.pwd)' → cwdMatch=\(shellPid.map(String.init) ?? "nil")")
            if shellPid == nil, let first = shells.first(where: { !usedShells.contains($0.shellPid) }) {
                shellPid = first.shellPid
                kLog("[ProcessUtil]     fallback to first unused shell: \(shellPid!)")
            }
            if let sp = shellPid { usedShells.insert(sp) }

            let target = shellPid ?? Foundation.ProcessInfo.processInfo.processIdentifier
            let fgPid = findDeepestChild(of: target, in: snapshot)
            let name = processName(of: fgPid, in: snapshot) ?? "shell"
            kLog("[ProcessUtil]     target=\(target) → fg=\(fgPid) name='\(name)'")
            updates.append((pane.id, name))
        }
        return updates
    }
}

// MARK: - Process Info View

struct ProcessEntry: Identifiable {
    let id = UUID()
    let pid: pid_t
    let ppid: pid_t
    let stat: String
    let cpu: String
    let rssMB: Double
    let command: String
    var depth: Int = 0

    var isRunning: Bool { !stat.hasPrefix("Z") && !stat.hasPrefix("T") }
    var statusColor: Color {
        if stat.hasPrefix("Z") { return .secondary }
        if stat.hasPrefix("T") { return .secondary.opacity(0.4) }
        if stat.hasPrefix("R") { return .primary.opacity(0.6) }
        return .secondary.opacity(0.6)
    }
}

struct KytosProcessInfoView: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var processes: [ProcessEntry] = []
    @State private var systemStats: SystemStats?
    @State private var isVisible = false
    @State private var shellPid: pid_t = 0

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                sessionHeader

                // Process tree glass card
                processTreeSection

                // System gauges glass card
                if let stats = systemStats {
                    systemGaugesSection(stats)
                }
            }
            .padding(10)
        }
        .scrollContentBackground(.hidden)
        .background(.clear)
        .onAppear {
            isVisible = true
            Task { await refresh() }
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: workspace.focusedPaneID) { _, _ in
            Task { await refresh() }
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            guard isVisible else { return }
            Task { await refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosProcessNamesUpdated"))) { _ in
            guard isVisible else { return }
            Task { await refresh() }
        }
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            let focusedID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
            let pane = workspace.splitTree.findPane(focusedID) ?? workspace.splitTree.firstLeaf
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(pane.processName.isEmpty ? "shell" : pane.processName)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if shellPid > 0 {
                    Text(String(shellPid))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Process Tree

    private var processTreeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Process Tree")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            if processes.isEmpty {
                HStack {
                    Spacer()
                    Text("No processes found")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.vertical, 8)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(processes) { entry in
                        let isDeepest = entry.id == processes.last?.id
                        HStack(spacing: 4) {
                            if entry.depth > 0 {
                                Color.clear.frame(width: CGFloat(entry.depth) * 12)
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.quaternary)
                            }
                            Circle()
                                .fill(isDeepest ? Color.accentColor : entry.statusColor)
                                .frame(width: 5, height: 5)
                            Text(entry.command)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
                            Text(String(entry.pid))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(String(format: "%.0f MB", entry.rssMB))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(entry.cpu)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - System Gauges

    private func systemGaugesSection(_ stats: SystemStats) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            glassGaugeRow(label: "CPU", value: stats.cpuUsage, icon: "cpu", tint: .secondary,
                          detail: String(format: "%.0f%%", stats.cpuUsage * 100))
            glassGaugeRow(label: "Memory", value: stats.memoryUsage, icon: "memorychip", tint: .secondary,
                          detail: String(format: "%.0f%%", stats.memoryUsage * 100))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(in: RoundedRectangle(cornerRadius: 12))
    }

    private func glassGaugeRow(label: String, value: Double, icon: String, tint: Color, detail: String) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(tint)
                    .frame(width: 12)
                Text(label)
                    .font(.system(size: 10))
                Spacer()
                Text(detail)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(geo.size.width * min(value, 1.0), 2))
                }
            }
            .frame(height: 6)
            .glassEffect(in: Capsule())
        }
    }

    @MainActor private func refresh() async {
        let focusedPaneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        let focusedPane = workspace.splitTree.findPane(focusedPaneID) ?? workspace.splitTree.firstLeaf
        let ourPid = Foundation.ProcessInfo.processInfo.processIdentifier

        let result = await Task.detached { () -> ([ProcessEntry], SystemStats?, pid_t) in
            let snapshot = KytosProcessUtil.psSnapshot()
            let shells = KytosProcessUtil.findShells(snapshot: snapshot)
            let matched = KytosProcessUtil.matchShell(for: focusedPane, from: shells, excluding: [])
            let resolvedShellPid = matched ?? shells.first?.shellPid ?? ourPid

            // Root tree at Kytos process to show full hierarchy
            let tree = Self.processTree(rootPID: ourPid)
            let stats = Self.systemStats()
            return (tree, stats, resolvedShellPid)
        }.value

        processes = result.0
        systemStats = result.1
        shellPid = result.2
    }

    nonisolated static func processTree(rootPID: pid_t) -> [ProcessEntry] {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid=,ppid=,stat=,pcpu=,rss=,comm="]
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return [] }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        task.waitUntilExit()

        var all: [pid_t: ProcessEntry] = [:]
        var children: [pid_t: [pid_t]] = [:]

        for line in out.components(separatedBy: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 6,
                  let pid = pid_t(cols[0]),
                  let ppid = pid_t(cols[1]) else { continue }
            let stat = String(cols[2])
            let cpu = String(cols[3]) + "%"
            let rss = Double(cols[4]).map { $0 / 1024 } ?? 0
            let cmd = cols[5...].joined(separator: " ")
            all[pid] = ProcessEntry(pid: pid, ppid: ppid, stat: stat, cpu: cpu, rssMB: rss, command: cmd)
            children[ppid, default: []].append(pid)
        }

        var result: [ProcessEntry] = []
        func walk(_ pid: pid_t, depth: Int) {
            guard var entry = all[pid] else { return }
            // Skip zombie processes — they're already dead and awaiting reaping
            guard !entry.stat.hasPrefix("Z") else { return }
            entry.depth = depth
            result.append(entry)
            for child in (children[pid] ?? []).sorted() {
                walk(child, depth: depth + 1)
            }
        }
        walk(rootPID, depth: 0)
        return result
    }
}

// MARK: - System Stats

struct SystemStats {
    let cpuUsage: Double
    let memoryUsage: Double
}

extension KytosProcessInfoView {
    nonisolated static func systemStats() -> SystemStats? {
        let cpu = systemCPU()
        let mem = systemMemory()
        return SystemStats(cpuUsage: cpu, memoryUsage: mem)
    }

    nonisolated private static func systemCPU() -> Double {
        var loadInfo = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &loadInfo) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let user = Double(loadInfo.cpu_ticks.0)
        let system = Double(loadInfo.cpu_ticks.1)
        let idle = Double(loadInfo.cpu_ticks.2)
        let nice = Double(loadInfo.cpu_ticks.3)

        struct Previous { nonisolated(unsafe) static var user = 0.0; nonisolated(unsafe) static var system = 0.0; nonisolated(unsafe) static var idle = 0.0; nonisolated(unsafe) static var nice = 0.0 }
        let dUser = user - Previous.user
        let dSystem = system - Previous.system
        let dIdle = idle - Previous.idle
        let dNice = nice - Previous.nice
        let dTotal = dUser + dSystem + dIdle + dNice
        Previous.user = user; Previous.system = system; Previous.idle = idle; Previous.nice = nice

        guard dTotal > 0 else { return 0 }
        return (dUser + dSystem + dNice) / dTotal
    }

    nonisolated private static func systemMemory() -> Double {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        let pageSize = Double(sysconf(_SC_PAGESIZE))
        let active = Double(stats.active_count) * pageSize
        let wired = Double(stats.wire_count) * pageSize
        let compressed = Double(stats.compressor_page_count) * pageSize
        let total = Double(Foundation.ProcessInfo.processInfo.physicalMemory)
        guard total > 0 else { return 0 }
        return (active + wired + compressed) / total
    }
}

// MARK: - Process Monitor (legacy single-process, kept for backward compat)

@Observable
@MainActor
final class KytosProcessMonitor {
    private(set) var processInfo: KytosProcessInfo?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var isVisible = false
    @ObservationIgnored private weak var targetView: KytosGhosttyView?
    @ObservationIgnored private var prevCPUTime: UInt64 = 0
    @ObservationIgnored private var prevSampleTime: CFAbsoluteTime = 0

    init() {}

    func setVisible(_ visible: Bool) {
        isVisible = visible
        if visible {
            startPolling()
        } else {
            stopPolling()
        }
    }

    func setView(_ view: KytosGhosttyView?) {
        targetView = view
        prevCPUTime = 0
        prevSampleTime = 0
        if isVisible { pollOnce() }
    }

    private func startPolling() {
        pollOnce()
        let interval = KytosSettings.shared.inspectorRefreshInterval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.pollOnce() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func updateInterval() {
        guard isVisible else { return }
        stopPolling()
        startPolling()
    }

    private func pollOnce() {
        guard let view = targetView else { return }

        let viewTitle = view.title
        let viewPwd = view.pwd
        let ourPid = Foundation.ProcessInfo.processInfo.processIdentifier
        let capturedPrevCPU = prevCPUTime
        let capturedPrevTime = prevSampleTime

        Task.detached {
            let snapshot = KytosProcessUtil.psSnapshot()
            let children = KytosProcessUtil.findAllChildren(of: ourPid, in: snapshot)
            let shellPid = children.first ?? ourPid
            let fgPid = shellPid > 0 ? KytosProcessUtil.findDeepestChild(of: shellPid, in: snapshot) : shellPid
            let targetPid = fgPid > 0 ? fgPid : (shellPid > 0 ? shellPid : ourPid)

            var taskInfo = proc_taskinfo()
            let taskSize = proc_pidinfo(targetPid, PROC_PIDTASKINFO, 0, &taskInfo, Int32(MemoryLayout<proc_taskinfo>.size))

            let now = CFAbsoluteTimeGetCurrent()
            var cpuPercent: Double = 0
            var memoryBytes: UInt64 = 0

            if taskSize > 0 {
                memoryBytes = taskInfo.pti_resident_size
                let totalCPUTime = taskInfo.pti_total_user + taskInfo.pti_total_system
                if capturedPrevTime > 0 {
                    let deltaTime = now - capturedPrevTime
                    if deltaTime > 0 {
                        let deltaCPU = Double(totalCPUTime - capturedPrevCPU) / 1_000_000_000.0
                        cpuPercent = (deltaCPU / deltaTime) * 100.0
                    }
                }

                await MainActor.run { [weak self] in
                    self?.prevCPUTime = totalCPUTime
                    self?.prevSampleTime = now
                }
            }

            var processName = viewTitle.isEmpty ? "shell" : viewTitle
            if targetPid != ourPid {
                if let name = KytosProcessUtil.processName(of: targetPid, in: snapshot), !name.isEmpty {
                    processName = name
                }
            }

            let info = KytosProcessInfo(
                name: processName,
                pid: targetPid,
                cpuPercent: cpuPercent,
                memoryBytes: memoryBytes,
                workingDirectory: viewPwd
            )

            await MainActor.run { [weak self] in
                self?.processInfo = info
            }
        }
    }

}

struct KytosProcessInfo {
    let name: String
    let pid: pid_t
    let cpuPercent: Double
    let memoryBytes: UInt64
    let workingDirectory: String
}

// MARK: - Panel Empty State

struct KytosPanelEmpty: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
