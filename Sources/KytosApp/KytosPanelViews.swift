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
                Text(pane.title.isEmpty ? "shell" : pane.title)
                    .font(.system(size: 11, weight: isFocused ? .medium : .regular))
                    .lineLimit(1)

                if let posPath = workspace.splitTree.positionPath(for: pane.id), workspace.splitTree.isSplit {
                    Text(posPath)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                if !pane.pwd.isEmpty {
                    Text(abbreviatePath(pane.pwd))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            // Close button (visible on hover, only if multiple panes)
            if isHovering && workspace.splitTree.isSplit {
                Button {
                    if let newFocusID = workspace.splitTree.remove(paneID: pane.id) {
                        workspace.focusedPaneID = newFocusID
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
        .contentShape(Rectangle())
        .glassEffect(in: RoundedRectangle(cornerRadius: 8))
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

// MARK: - Process Info View

import AppKit
import Darwin

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
    }

    private var sessionHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text(workspace.session.name)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text(workspace.session.id.uuidString.prefix(8))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
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
        // Find the shell PID for the focused surface
        let focusedPaneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        let focusedPwd = workspace.splitTree.findPane(focusedPaneID)?.pwd ?? ""
        let ourPid = Foundation.ProcessInfo.processInfo.processIdentifier

        // Find which shell belongs to this surface by CWD matching
        let result = await Task.detached { () -> ([ProcessEntry], SystemStats?, pid_t) in
            let children = Self.findAllChildren(of: ourPid)

            // Match child whose CWD matches the focused pane's pwd
            var matchedPid: pid_t?
            if !focusedPwd.isEmpty {
                for child in children {
                    if let cwd = Self.cwdForPid(child), cwd == focusedPwd || cwd.hasPrefix(focusedPwd) || focusedPwd.hasPrefix(cwd) {
                        matchedPid = child
                        break
                    }
                }
            }
            let shellPid = matchedPid ?? children.first ?? ourPid

            let tree = Self.processTree(rootPID: shellPid)
            let stats = Self.systemStats()
            return (tree, stats, shellPid)
        }.value

        processes = result.0
        systemStats = result.1
        shellPid = result.2
    }

    /// Get the current working directory of a process via proc_pidinfo.
    nonisolated private static func cwdForPid(_ pid: pid_t) -> String? {
        var vnodeInfo = proc_vnodepathinfo()
        let size = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnodeInfo, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard size > 0 else { return nil }
        return withUnsafePointer(to: vnodeInfo.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    // MARK: - Process Tree Builder

    nonisolated private static func findAllChildren(of parentPid: pid_t) -> [pid_t] {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return [] }
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let actualCount = Int(actual) / MemoryLayout<pid_t>.size

        var children: [pid_t] = []
        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var bsdInfo = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size > 0 && bsdInfo.pbi_ppid == UInt32(parentPid) {
                children.append(pid)
            }
        }
        return children.sorted()
    }

    nonisolated private static func processTree(rootPID: pid_t) -> [ProcessEntry] {
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
            let shellPid = Self.findChildProcess(of: ourPid)
            let fgPid = shellPid > 0 ? Self.findDeepestChild(of: shellPid) : shellPid
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
                var bsdInfo = proc_bsdinfo()
                let bsdSize = proc_pidinfo(targetPid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
                if bsdSize > 0 {
                    let name = withUnsafePointer(to: bsdInfo.pbi_comm) { ptr in
                        ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
                    }
                    if !name.isEmpty { processName = name }
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

    nonisolated private static func findChildProcess(of parentPid: pid_t) -> pid_t {
        let bufferSize = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bufferSize > 0 else { return 0 }
        let count = Int(bufferSize) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, bufferSize)
        let actualCount = Int(actual) / MemoryLayout<pid_t>.size

        for i in 0..<actualCount {
            let pid = pids[i]
            guard pid > 0 else { continue }
            var bsdInfo = proc_bsdinfo()
            let size = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsdInfo, Int32(MemoryLayout<proc_bsdinfo>.size))
            if size > 0 && bsdInfo.pbi_ppid == UInt32(parentPid) {
                return pid
            }
        }
        return 0
    }

    nonisolated private static func findDeepestChild(of pid: pid_t) -> pid_t {
        var current = pid
        for _ in 0..<10 {
            let child = findChildProcess(of: current)
            if child <= 0 { break }
            current = child
        }
        return current
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
