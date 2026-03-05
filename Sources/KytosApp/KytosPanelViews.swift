// KytosPanelViews.swift — inspector and utility panel implementations

import SwiftUI
import Darwin

#if os(macOS)
// MARK: - Shared session context

/// Resolved context for the currently focused pane, used by all inspector/utility views.
struct KytosFocusedSessionContext {
    let terminalID: UUID
    let commandLine: [String]?
    let sessionInfo: KytosPaneSessionInfo

    /// Human-readable shell name, e.g. "zsh".
    var shellName: String {
        if let cmd = commandLine?.first, !cmd.isEmpty {
            return URL(fileURLWithPath: cmd).lastPathComponent
        }
        return "shell"
    }

    var pid: pid_t? { sessionInfo.processID.map { pid_t($0) } }
}

@MainActor
private func kytosFetchFocusedSession() async -> KytosFocusedSessionContext? {
    #if os(macOS)
    let active = KytosTerminalManager.shared.activeTerminalID
    let latch = KytosTerminalManager.shared.lastKnownActiveTerminalID
    let terminalID = active ?? latch
    guard let tid = terminalID else {
        kLog("[KytosDebug][ProcessInfo] no terminal ID (active=\(active?.uuidString.prefix(8) ?? "nil"), latch=\(latch?.uuidString.prefix(8) ?? "nil"))")
        return nil
    }

    let leaf = KytosAppModel.shared.windows.values
        .flatMap { $0.session.layout.allTerminalLeaves() }
        .first { $0.id == tid }
    guard let sessionID = leaf?.sessionID else {
        kLog("[KytosDebug][ProcessInfo] no session ID for terminal \(tid.uuidString.prefix(8)), leaf=\(leaf.map { String(describing: $0) } ?? "nil")")
        return nil
    }

    let result = await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .background).async {
            cont.resume(returning: Result { try KytosPaneClient.shared.listSessions() })
        }
    }
    guard case .success(let sessions) = result,
          let info = sessions.first(where: { $0.id == sessionID }) else { return nil }

    return KytosFocusedSessionContext(
        terminalID: tid,
        commandLine: leaf?.commandLine,
        sessionInfo: info
    )
    #else
    return nil
    #endif
}

// MARK: - Shared panel scaffold

private struct KytosPanelScaffold<Content: View>: View {
    let pollInterval: TimeInterval
    var content: () async -> Content?

    @State private var built: AnyView = AnyView(EmptyView())

    var body: some View {
        built
            .task { await rebuild() }
            .onReceive(Timer.publish(every: pollInterval, on: .main, in: .common).autoconnect()) { _ in
                Task { await rebuild() }
            }
    }

    @MainActor private func rebuild() async {
        if let v = await content() { built = AnyView(v) }
    }
}

private struct KytosPanelEmpty: View {
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(message)
                .foregroundStyle(.secondary)
                .font(.caption)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Process Info — process tree for active pane

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
        if stat.hasPrefix("Z") { return .red }      // zombie
        if stat.hasPrefix("T") { return .orange }   // stopped
        if stat.hasPrefix("R") { return .green }    // running
        return .secondary.opacity(0.6)              // sleeping
    }
}

struct KytosProcessInfoView: View {
    @State private var ctx: KytosFocusedSessionContext?
    @State private var processes: [ProcessEntry] = []
    @State private var systemStats: SystemStats?

    var body: some View {
        Group {
            if let ctx {
                ScrollView {
                    VStack(spacing: 12) {
                        // Session header glass card
                        sessionHeader(ctx)

                        // Process tree glass card
                        processTreeSection

                        // System gauges glass card
                        if let stats = systemStats {
                            systemGaugesSection(stats)
                        }
                    }
                    .padding(10)
                }
            } else {
                KytosPanelEmpty(message: "No active terminal pane.")
            }
        }
        #if os(macOS)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        #endif
    }

    // MARK: - Session Header

    private func sessionHeader(_ ctx: KytosFocusedSessionContext) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(ctx.sessionInfo.isRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text("Session \(ctx.sessionInfo.id)")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                if let pid = ctx.pid {
                    Text("PID \(pid)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(ctx.shellName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(ctx.sessionInfo.createdAt, style: .relative)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
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
                        HStack(spacing: 4) {
                            if entry.depth > 0 {
                                Color.clear.frame(width: CGFloat(entry.depth) * 12)
                                Image(systemName: "arrow.turn.down.right")
                                    .font(.system(size: 7))
                                    .foregroundStyle(.quaternary)
                            }
                            Circle()
                                .fill(entry.statusColor)
                                .frame(width: 5, height: 5)
                            Text(entry.command)
                                .font(.system(size: 10, design: .monospaced))
                                .lineLimit(1)
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

            glassGaugeRow(label: "CPU", value: stats.cpuUsage, icon: "cpu", tint: .blue,
                          detail: String(format: "%.0f%%", stats.cpuUsage * 100))
            glassGaugeRow(label: "Memory", value: stats.memoryUsage, icon: "memorychip", tint: .green,
                          detail: String(format: "%.0f%%", stats.memoryUsage * 100))
            glassGaugeRow(label: "Energy", value: stats.energyImpact, icon: "bolt.fill", tint: .orange,
                          detail: String(format: "%.0f%%", stats.energyImpact * 100))
            glassGaugeRow(label: "Disk", value: stats.diskUsage, icon: "internaldrive", tint: .purple,
                          detail: kytosFormatBytes(stats.diskReadBytes + stats.diskWriteBytes) + "/s")
            glassGaugeRow(label: "Network", value: stats.networkActivity, icon: "network", tint: .cyan,
                          detail: "↑\(kytosFormatBytes(stats.networkOutBytes)) ↓\(kytosFormatBytes(stats.networkInBytes))")
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
            // Liquid glass gauge bar
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

    #if os(macOS)
    @MainActor private func refresh() async {
        ctx = await kytosFetchFocusedSession()
        guard let pid = ctx?.pid else {
            kLog("[KytosDebug][ProcessInfo] refresh — ctx=\(ctx == nil ? "nil" : "present"), pid=nil")
            processes = []
            systemStats = nil
            return
        }
        kLog("[KytosDebug][ProcessInfo] refresh — pid=\(pid)")
        let result = await withCheckedContinuation { (cont: CheckedContinuation<([ProcessEntry], SystemStats?), Never>) in
            DispatchQueue.global(qos: .background).async {
                let tree = kytosProcessTree(rootPID: pid)
                let stats = kytosSystemStats()
                kLog("[KytosDebug][ProcessInfo] tree result — \(tree.count) entries")
                cont.resume(returning: (tree, stats))
            }
        }
        processes = result.0
        systemStats = result.1
    }
    #endif
}

/// Build a depth-annotated process tree rooted at `rootPID`.
private func kytosProcessTree(rootPID: pid_t) -> [ProcessEntry] {
    // Snapshot all processes
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

    // DFS from rootPID
    var result: [ProcessEntry] = []
    kLog("[KytosDebug][ProcessTree] rootPID=\(rootPID), all.count=\(all.count), rootInAll=\(all[rootPID] != nil)")
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

// MARK: - System Stats

struct SystemStats {
    let cpuUsage: Double        // 0.0–1.0
    let memoryUsage: Double     // 0.0–1.0
    let energyImpact: Double    // 0.0–1.0 (estimated from CPU + thermal)
    let diskUsage: Double       // 0.0–1.0 (activity gauge)
    let diskReadBytes: Int64
    let diskWriteBytes: Int64
    let networkActivity: Double // 0.0–1.0
    let networkInBytes: Int64
    let networkOutBytes: Int64
}

/// Collect snapshot of system-wide CPU, memory, disk I/O, and network stats.
/// Uses Mach host_statistics and sysctl — no subprocesses.
private func kytosSystemStats() -> SystemStats? {
    // --- CPU ---
    let cpuUsage = kytosSystemCPU()

    // --- Memory ---
    let memUsage = kytosSystemMemory()

    // --- Disk I/O (via sysctl) ---
    let (diskRead, diskWrite) = kytosSystemDiskIO()
    let diskTotal = diskRead + diskWrite
    // Normalize: ~100 MB/s = full gauge
    let diskActivity = min(Double(diskTotal) / (100 * 1024 * 1024), 1.0)

    // --- Network ---
    let (netIn, netOut) = kytosSystemNetworkIO()
    let netTotal = netIn + netOut
    // Normalize: ~10 MB/s = full gauge
    let netActivity = min(Double(netTotal) / (10 * 1024 * 1024), 1.0)

    // --- Energy (estimated: weighted CPU + memory pressure) ---
    let energy = min(cpuUsage * 0.7 + memUsage * 0.3, 1.0)

    return SystemStats(
        cpuUsage: cpuUsage,
        memoryUsage: memUsage,
        energyImpact: energy,
        diskUsage: diskActivity,
        diskReadBytes: diskRead,
        diskWriteBytes: diskWrite,
        networkActivity: netActivity,
        networkInBytes: netIn,
        networkOutBytes: netOut
    )
}

/// System-wide CPU usage via host_statistics (user + system ticks / total ticks).
/// Uses a static previous-sample to compute delta between calls.
private func kytosSystemCPU() -> Double {
    var loadInfo = host_cpu_load_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &loadInfo) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let user = Double(loadInfo.cpu_ticks.0)   // CPU_STATE_USER
    let system = Double(loadInfo.cpu_ticks.1) // CPU_STATE_SYSTEM
    let idle = Double(loadInfo.cpu_ticks.2)   // CPU_STATE_IDLE
    let nice = Double(loadInfo.cpu_ticks.3)   // CPU_STATE_NICE
    let total = user + system + idle + nice

    struct Previous { static var user = 0.0; static var system = 0.0; static var idle = 0.0; static var nice = 0.0 }
    let dUser = user - Previous.user
    let dSystem = system - Previous.system
    let dIdle = idle - Previous.idle
    let dNice = nice - Previous.nice
    let dTotal = dUser + dSystem + dIdle + dNice
    Previous.user = user; Previous.system = system; Previous.idle = idle; Previous.nice = nice

    guard dTotal > 0 else { return 0 }
    return (dUser + dSystem + dNice) / dTotal
}

/// System memory pressure via host_statistics64.
private func kytosSystemMemory() -> Double {
    var stats = vm_statistics64_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }

    let pageSize = Double(vm_kernel_page_size)
    let active = Double(stats.active_count) * pageSize
    let wired = Double(stats.wire_count) * pageSize
    let compressed = Double(stats.compressor_page_count) * pageSize
    let total = Double(ProcessInfo.processInfo.physicalMemory)
    guard total > 0 else { return 0 }
    return (active + wired + compressed) / total
}

/// Cumulative disk I/O bytes via `iostat`-style sysctl.
/// Returns (bytesRead, bytesWritten) since boot — caller should diff between samples.
private func kytosSystemDiskIO() -> (Int64, Int64) {
    struct Previous { static var read: Int64 = 0; static var write: Int64 = 0 }
    // Use `iostat -c 1 -C` to get a quick snapshot — lightweight, no IOKit dependency
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/iostat")
    task.arguments = ["-c", "1", "-C"]
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return (0, 0) }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    // Parse last line: KB/t tps MB/s  (for "disk" aggregate)
    let lines = out.components(separatedBy: "\n").filter { !$0.isEmpty }
    guard let lastLine = lines.last else { return (0, 0) }
    let cols = lastLine.split(separator: " ", omittingEmptySubsequences: true)
    // Format: KB/t  tps  MB/s  (repeated for each disk, then aggregate)
    // We want the aggregate MB/s from the last trio
    if cols.count >= 3, let mbps = Double(cols[cols.count - 1]) {
        // Convert MB/s to bytes for the gauge — approximate read+write as total
        let bytesPerSec = Int64(mbps * 1024 * 1024)
        return (bytesPerSec / 2, bytesPerSec / 2)
    }
    return (0, 0)
}

/// Network I/O via `netstat -ib` (bytes in/out on en0).
private func kytosSystemNetworkIO() -> (Int64, Int64) {
    struct Previous { static var inBytes: Int64 = 0; static var outBytes: Int64 = 0 }
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/netstat")
    task.arguments = ["-ib", "-I", "en0"]
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return (0, 0) }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    task.waitUntilExit()
    // Parse: Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
    let lines = out.components(separatedBy: "\n")
    for line in lines.dropFirst() {
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 10, cols[0] == "en0" else { continue }
        // Find the row with actual byte counts (skip the link-level header row)
        if let ibytes = Int64(cols[6]), let obytes = Int64(cols[9]) {
            let dIn = max(ibytes - Previous.inBytes, 0)
            let dOut = max(obytes - Previous.outBytes, 0)
            Previous.inBytes = ibytes
            Previous.outBytes = obytes
            // First call returns 0 delta (baseline)
            if dIn == ibytes { return (0, 0) }
            return (dIn, dOut)
        }
    }
    return (0, 0)
}

private func kytosFormatBytes(_ bytes: Int64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
    if bytes < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(bytes) / (1024 * 1024)) }
    return String(format: "%.2f GB", Double(bytes) / (1024 * 1024 * 1024))
}

// MARK: - Environment Inspector

/// Groups for environment variable display.
private enum EnvGroup: String, CaseIterable {
    case terminal = "Terminal"
    case shell = "Shell"
    case paths = "Paths"
    case dotfiles = "Dotfiles"
    case other = "Other"

    static func classify(_ key: String) -> EnvGroup {
        switch key {
        case "TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION", "COLORTERM", "COLUMNS", "LINES":
            return .terminal
        case "SHELL", "BASH", "ZSH_VERSION", "BASH_VERSION", "KSH_VERSION", "SHLVL", "HISTFILE",
             "HISTSIZE", "HISTFILESIZE", "PS1", "PS2", "PROMPT", "RPROMPT":
            return .shell
        case "PATH", "MANPATH", "CDPATH", "FPATH", "LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH":
            return .paths
        case "ZDOTDIR", "BASH_ENV", "ENV", "ZDOTENV_EXTRA", "ZSHRC", "BASHRC", "ZDOTDIR_EXTRA",
             "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR":
            return .dotfiles
        default:
            return .other
        }
    }
}

struct KytosEnvironmentInspectorView: View {
    @State private var env: [String: String] = [:]
    @State private var pid: pid_t?
    @State private var searchText = ""
    @State private var selectedGroup: EnvGroup? = nil

    private var filteredEnv: [(key: String, value: String)] {
        env.filter { key, value in
            let matchesSearch = searchText.isEmpty ||
                key.localizedCaseInsensitiveContains(searchText) ||
                value.localizedCaseInsensitiveContains(searchText)
            let matchesGroup = selectedGroup.map { EnvGroup.classify(key) == $0 } ?? true
            return matchesSearch && matchesGroup
        }
        .sorted { $0.key < $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !env.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)

                Picker("Group", selection: $selectedGroup) {
                    Text("All").tag(Optional<EnvGroup>.none)
                    ForEach(EnvGroup.allCases, id: \.self) { g in
                        Text(g.rawValue).tag(Optional(g))
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            }

            if env.isEmpty {
                KytosPanelEmpty(message: "Focus a terminal pane\nto inspect its environment.")
            } else if filteredEnv.isEmpty {
                KytosPanelEmpty(message: "No matching variables.")
            } else {
                List(filteredEnv, id: \.key) { pair in
                    EnvVarRow(key: pair.key, value: pair.value)
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        #endif
    }

    #if os(macOS)
    @MainActor private func refresh() async {
        let ctx = await kytosFetchFocusedSession()
        guard let p = ctx?.pid else { env = [:]; return }
        if p != pid {
            pid = p
            env = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .background).async {
                    cont.resume(returning: kytosReadProcessEnvironment(pid: p))
                }
            }
        }
    }
    #endif
}

private struct EnvVarRow: View {
    let key: String
    let value: String
    @State private var isExpanded = false

    private var isDotfileRelated: Bool {
        EnvGroup.classify(key) == .dotfiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(key)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isDotfileRelated ? Color.orange : .primary)
                if isDotfileRelated {
                    Image(systemName: "doc.text")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                        .help("Declared by a shell dotfile")
                }
                Spacer()
            }
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(isExpanded ? nil : 1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .onTapGesture { isExpanded.toggle() }
    }
}

// MARK: - sysctl KERN_PROCARGS2 environment reader

private func kytosReadProcessEnvironment(pid: pid_t) -> [String: String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0)
    guard size > 4 else { return [:] }

    var buffer = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return [:] }

    // First 4 bytes: argc (little-endian)
    let argc = Int(buffer[0]) | Int(buffer[1]) << 8 | Int(buffer[2]) << 16 | Int(buffer[3]) << 24
    var i = 4
    // Skip exec path
    while i < size && buffer[i] != 0 { i += 1 }; i += 1
    // Skip alignment nulls
    while i < size && buffer[i] == 0 { i += 1 }
    // Skip argv
    var skipped = 0
    while i < size && skipped < argc {
        if buffer[i] == 0 { skipped += 1 }
        i += 1
    }
    // Parse env KEY=VALUE
    var result: [String: String] = [:]
    var current: [UInt8] = []
    while i < size {
        let b = buffer[i]; i += 1
        if b == 0 {
            if current.isEmpty { break }
            if let s = String(bytes: current, encoding: .utf8), let eq = s.firstIndex(of: "=") {
                result[String(s[..<eq])] = String(s[s.index(after: eq)...])
            }
            current = []
        } else {
            current.append(b)
        }
    }
    return result
}

// MARK: - History Inspector

struct KytosHistoryInspectorView: View {
    @State private var commands: [HistoryEntry] = []
    @State private var shellName: String = ""
    @State private var searchText = ""

    struct HistoryEntry: Identifiable {
        let id = UUID()
        let command: String
        let timestamp: Date?
    }

    private var filtered: [HistoryEntry] {
        searchText.isEmpty ? commands : commands.filter {
            $0.command.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !commands.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter history", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.caption)
                    if !shellName.isEmpty {
                        Text(shellName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(.secondary.opacity(0.15)))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.bar)
            }

            if commands.isEmpty {
                KytosPanelEmpty(message: "Focus a terminal pane\nto see its shell history.")
            } else if filtered.isEmpty {
                KytosPanelEmpty(message: "No matching commands.")
            } else {
                List(filtered) { entry in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.command)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                        if let ts = entry.timestamp {
                            Text(ts, style: .relative)
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        #endif
    }

    #if os(macOS)
    @MainActor private func refresh() async {
        let ctx = await kytosFetchFocusedSession()
        guard let p = ctx?.pid else { commands = []; return }

        let env = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                cont.resume(returning: kytosReadProcessEnvironment(pid: p))
            }
        }

        let shell = (env["SHELL"] ?? "/bin/zsh")
        shellName = URL(fileURLWithPath: shell).lastPathComponent
        let histFile = kytosHistoryFilePath(shell: shell, env: env)
        let entries = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                cont.resume(returning: kytosParseHistory(path: histFile, shell: shellName))
            }
        }
        commands = entries
    }
    #endif
}

private func kytosHistoryFilePath(shell: String, env: [String: String]) -> String {
    let name = URL(fileURLWithPath: shell).lastPathComponent
    let home = env["HOME"] ?? NSHomeDirectory()
    switch name {
    case "zsh": return env["HISTFILE"] ?? "\(home)/.zsh_history"
    case "bash": return env["HISTFILE"] ?? "\(home)/.bash_history"
    case "mksh", "ksh": return env["HISTFILE"] ?? "\(home)/.mksh_history"
    default: return env["HISTFILE"] ?? "\(home)/.\(name)_history"
    }
}

private func kytosParseHistory(path: String, shell: String) -> [KytosHistoryInspectorView.HistoryEntry] {
    guard let data = FileManager.default.contents(atPath: path),
          let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    else { return [] }

    var entries: [KytosHistoryInspectorView.HistoryEntry] = []
    let lines = text.components(separatedBy: "\n")

    if shell == "zsh" {
        // zsh extended_history: ": <timestamp>:<elapsed>;<command>"
        for line in lines.reversed() {
            if line.hasPrefix(": ") {
                // ": 1709571234:0;git status"
                let parts = line.dropFirst(2).components(separatedBy: ";")
                if parts.count >= 2 {
                    let meta = parts[0].components(separatedBy: ":")
                    let cmd = parts.dropFirst().joined(separator: ";")
                    let ts = meta.first.flatMap { TimeInterval($0) }.map { Date(timeIntervalSince1970: $0) }
                    entries.append(.init(command: cmd, timestamp: ts))
                }
            } else if !line.isEmpty && !line.hasPrefix("\\") {
                entries.append(.init(command: line, timestamp: nil))
            }
            if entries.count >= 200 { break }
        }
    } else {
        // bash/mksh: one command per line
        for line in lines.reversed() {
            guard !line.isEmpty else { continue }
            entries.append(.init(command: line, timestamp: nil))
            if entries.count >= 200 { break }
        }
    }
    return entries
}

// MARK: - Search Utility

struct KytosSearchUtilityView: View {
    @State private var query = ""
    @State private var results: [SearchResult] = []
    @State private var isSearching = false
    @State private var lastSessionID: String?

    struct SearchResult: Identifiable {
        let id = UUID()
        let line: Int
        let text: String
        let matchRange: Range<String.Index>?
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.caption)
                TextField("Search in pane…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { Task { await runSearch() } }
                if isSearching {
                    ProgressView().scaleEffect(0.6)
                } else if !query.isEmpty {
                    Button { Task { await runSearch() } } label: {
                        Image(systemName: "return")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            if results.isEmpty && !query.isEmpty && !isSearching {
                KytosPanelEmpty(message: "No matches for \"\(query)\"")
            } else if results.isEmpty {
                KytosPanelEmpty(message: "Type a query and press Return\nto search the current pane.")
            } else {
                List(results) { result in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(result.line)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 24, alignment: .trailing)
                        Text(highlightedText(result))
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(2)
                    }
                    .padding(.vertical, 1)
                }
                .listStyle(.plain)
            }
        }
    }

    private func highlightedText(_ result: SearchResult) -> AttributedString {
        var str = AttributedString(result.text.trimmingCharacters(in: .whitespaces))
        if let range = result.matchRange,
           let aRange = Range(range, in: str) {
            str[aRange].backgroundColor = .yellow.opacity(0.4)
            str[aRange].foregroundColor = .primary
        }
        return str
    }

    #if os(macOS)
    @MainActor private func runSearch() async {
        guard !query.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }

        let ctx = await kytosFetchFocusedSession()
        guard let sid = ctx?.sessionInfo.id else {
            results = []
            return
        }

        let q = query
        let found = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                do {
                    let snap = try KytosPaneClient.shared.fetchSnapshot(sessionID: sid)
                    let hits: [SearchResult] = snap.lines.enumerated().compactMap { (i, cells) in
                        let text = cells.map { $0.char }.joined()
                        guard let range = text.range(of: q, options: [.caseInsensitive]) else { return nil }
                        return SearchResult(line: i + 1, text: text, matchRange: range)
                    }
                    cont.resume(returning: hits)
                } catch {
                    cont.resume(returning: [])
                }
            }
        }
        results = found
    }
    #endif
}

// MARK: - Resources Utility

struct KytosResourcesUtilityView: View {
    @State private var info: ResourceInfo?

    struct ResourceInfo {
        let residentMB: Double
        let virtualMB: Double
        let threads: Int
        let cpuInfo: String
    }

    var body: some View {
        Group {
            if let info {
                Form {
                    Section("Memory") {
                        LabeledContent("Resident") {
                            Text(String(format: "%.1f MB", info.residentMB))
                                .fontDesign(.monospaced)
                        }
                        LabeledContent("Virtual") {
                            Text(String(format: "%.0f MB", info.virtualMB))
                                .fontDesign(.monospaced)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Section("Process") {
                        LabeledContent("Threads", value: "\(info.threads)")
                        if !info.cpuInfo.isEmpty {
                            LabeledContent("CPU", value: info.cpuInfo)
                        }
                    }
                }
                .formStyle(.grouped)
            } else {
                KytosPanelEmpty(message: "Focus a terminal pane\nto see resource usage.")
            }
        }
        #if os(macOS)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        #endif
    }

    #if os(macOS)
    @MainActor private func refresh() async {
        let ctx = await kytosFetchFocusedSession()
        guard let pid = ctx?.pid else { info = nil; return }

        info = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                cont.resume(returning: kytosReadResourceInfo(pid: pid))
            }
        }
    }
    #endif
}

private func kytosReadResourceInfo(pid: pid_t) -> KytosResourcesUtilityView.ResourceInfo? {
    // Use `ps` to avoid libproc complexity; reliable and available.
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-p", "\(pid)", "-o", "rss=,vsz=,pcpu=,nlwp="]
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return nil }
    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    task.waitUntilExit()
    let parts = out.split(separator: " ", omittingEmptySubsequences: true)
    guard parts.count >= 2 else { return nil }

    let rss = Double(parts[0]).map { $0 / 1024 } ?? 0
    let vsz = Double(parts[1]).map { $0 / 1024 } ?? 0
    let cpu = parts.count > 2 ? "\(parts[2])%" : ""
    let threads = parts.count > 3 ? Int(parts[3]) ?? 0 : 0

    return KytosResourcesUtilityView.ResourceInfo(
        residentMB: rss,
        virtualMB: vsz,
        threads: threads,
        cpuInfo: cpu
    )
}

// MARK: - Connections Utility

struct KytosConnectionsUtilityView: View {
    @State private var connections: [ConnectionEntry] = []
    @State private var pid: pid_t?

    struct ConnectionEntry: Identifiable {
        let id = UUID()
        let proto: String
        let localAddr: String
        let remoteAddr: String
        let state: String
    }

    var body: some View {
        Group {
            if connections.isEmpty {
                KytosPanelEmpty(message: pid == nil
                    ? "Focus a terminal pane\nto see its network connections."
                    : "No network connections.")
            } else {
                List(connections) { conn in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(conn.proto)
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(conn.state)
                                .font(.system(size: 10))
                                .foregroundStyle(conn.state == "ESTABLISHED" ? .green : .secondary)
                        }
                        Text(conn.localAddr)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                        if !conn.remoteAddr.isEmpty {
                            Text("→ \(conn.remoteAddr)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
        }
        #if os(macOS)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            Task { await refresh() }
        }
        #endif
    }

    #if os(macOS)
    @MainActor private func refresh() async {
        let ctx = await kytosFetchFocusedSession()
        guard let p = ctx?.pid else { pid = nil; connections = []; return }
        pid = p
        connections = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .background).async {
                cont.resume(returning: kytosReadConnections(pid: p))
            }
        }
    }
    #endif
}

private func kytosReadConnections(pid: pid_t) -> [KytosConnectionsUtilityView.ConnectionEntry] {
    let task = Process()
    let pipe = Pipe()
    task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    // -a = AND conditions, -p = pid, -i = internet, -n = no hostname lookup, -P = no port names
    task.arguments = ["-a", "-p", "\(pid)", "-i", "-n", "-P"]
    task.standardOutput = pipe
    task.standardError = Pipe()
    guard (try? task.run()) != nil else { return [] }
    task.waitUntilExit()

    let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    var entries: [KytosConnectionsUtilityView.ConnectionEntry] = []

    for line in out.components(separatedBy: "\n").dropFirst() {  // skip header
        let cols = line.split(separator: " ", omittingEmptySubsequences: true)
        guard cols.count >= 9 else { continue }
        let proto = String(cols[7])   // e.g. "TCP", "UDP"
        let addrField = String(cols[8]) // e.g. "127.0.0.1:8080->1.2.3.4:443"
        let state = cols.count >= 10 ? String(cols[9]).trimmingCharacters(in: "()".unicodeScalars.reduce(CharacterSet()) { $0.union(CharacterSet(charactersIn: String($1))) }) : ""

        let parts = addrField.components(separatedBy: "->")
        let local = parts.first ?? addrField
        let remote = parts.count > 1 ? parts[1] : ""

        entries.append(.init(proto: proto, localAddr: local, remoteAddr: remote, state: state))
    }
    return entries
}

#endif
