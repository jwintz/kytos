// KytosToolbar.swift — Starship-powered toolbar showing prompt segments

import SwiftUI
import AppKit

struct KytosSwiftShipToolbar: View {
    @Environment(KytosWorkspace.self) private var workspace
    @State private var leftPrompt: NSAttributedString = NSAttributedString()
    @State private var rightPrompt: NSAttributedString = NSAttributedString()
    @State private var refreshTimer: Timer?
    @State private var debounceTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: 8) {
            // Left prompt pill
            if leftPrompt.length > 0 {
                AttributedTextView(attributedString: leftPrompt)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
            }

            Spacer()

            // Right prompt pill
            if rightPrompt.length > 0 {
                AttributedTextView(attributedString: rightPrompt)
                    .fixedSize()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial)
                    .clipShape(Capsule())
            }
        }
        .onAppear {
            debouncedRefresh()
            startPeriodicRefresh()
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
            debounceTask?.cancel()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("KytosGhosttyPwd"))) { _ in
            debouncedRefresh()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            debouncedRefresh()
        }
        .onChange(of: workspace.focusedPaneID) { _, _ in
            debouncedRefresh()
        }
    }

    private func startPeriodicRefresh() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in debouncedRefresh() }
        }
    }

    private func debouncedRefresh() {
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    private func refresh() async {
        let focusedPaneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        let pane = workspace.splitTree.findPane(focusedPaneID) ?? workspace.splitTree.firstLeaf
        let pwd = pane.pwd.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.path : pane.pwd

        async let leftResult = StarshipRunner.run(pwd: pwd, right: false)
        async let rightResult = StarshipRunner.run(pwd: pwd, right: true)

        let (left, right) = await (leftResult, rightResult)
        leftPrompt = left
        rightPrompt = right
    }
}

// MARK: - Starship Process Runner

private enum StarshipRunner {
    static func run(pwd: String, right: Bool) async -> NSAttributedString {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = runSync(pwd: pwd, right: right)
                continuation.resume(returning: result)
            }
        }
    }

    private static func runSync(pwd: String, right: Bool) -> NSAttributedString {
        // Find starship binary
        let candidates = [
            "/Users/jwintz/.pixi/bin/starship",
            "/opt/homebrew/bin/starship",
            "/usr/local/bin/starship",
        ]
        guard let starshipPath = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return NSAttributedString()
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: starshipPath)
        var args = ["prompt"]
        if right { args.append("--right") }
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: pwd)
        process.environment = [
            "STARSHIP_SHELL": "sh",
            "TERM": "xterm-256color",
            "HOME": NSHomeDirectory(),
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        ]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return NSAttributedString()
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else {
            return NSAttributedString()
        }

        // Strip zsh prompt escape wrappers (%{…%}) that starship may emit
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "%{", with: "")
            .replacingOccurrences(of: "%}", with: "")
        return ANSIParser.parse(cleaned)
    }
}

// MARK: - ANSI SGR Parser

private enum ANSIParser {
    static func parse(_ input: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let monoFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let monoBoldFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)

        var currentFG: NSColor = .labelColor
        var currentBold = false
        var buffer = ""

        let pattern = #"\x1b\[([0-9;]*)m"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return NSAttributedString(string: input, attributes: [.font: monoFont])
        }

        let nsInput = input as NSString
        var lastEnd = 0

        let matches = regex.matches(in: input, range: NSRange(location: 0, length: nsInput.length))
        for match in matches {
            // Append text before this escape
            if match.range.location > lastEnd {
                let text = nsInput.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
                let cleaned = stripNonSGR(text)
                if !cleaned.isEmpty {
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: currentBold ? monoBoldFont : monoFont,
                        .foregroundColor: currentFG,
                    ]
                    result.append(NSAttributedString(string: cleaned, attributes: attrs))
                }
            }

            // Parse SGR params
            let params = nsInput.substring(with: match.range(at: 1))
            let codes = params.split(separator: ";").compactMap { Int($0) }
            if codes.isEmpty {
                // \e[m = reset
                currentFG = .labelColor
                currentBold = false
            } else {
                var i = 0
                while i < codes.count {
                    let code = codes[i]
                    switch code {
                    case 0:
                        currentFG = .labelColor
                        currentBold = false
                    case 1:
                        currentBold = true
                    case 22:
                        currentBold = false
                    case 30...37:
                        currentFG = standardColor(code - 30, bright: currentBold)
                    case 38:
                        // Extended color
                        if i + 1 < codes.count {
                            if codes[i + 1] == 5, i + 2 < codes.count {
                                currentFG = ansi256Color(codes[i + 2])
                                i += 2
                            } else if codes[i + 1] == 2, i + 4 < codes.count {
                                currentFG = NSColor(
                                    red: CGFloat(codes[i + 2]) / 255,
                                    green: CGFloat(codes[i + 3]) / 255,
                                    blue: CGFloat(codes[i + 4]) / 255,
                                    alpha: 1
                                )
                                i += 4
                            }
                        }
                    case 39:
                        currentFG = .labelColor
                    case 90...97:
                        currentFG = standardColor(code - 90, bright: true)
                    default:
                        break // Ignore bg colors and other attributes
                    }
                    i += 1
                }
            }
            lastEnd = match.range.location + match.range.length
        }

        // Append remaining text
        if lastEnd < nsInput.length {
            let text = nsInput.substring(from: lastEnd)
            let cleaned = stripNonSGR(text)
            if !cleaned.isEmpty {
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: currentBold ? monoBoldFont : monoFont,
                    .foregroundColor: currentFG,
                ]
                result.append(NSAttributedString(string: cleaned, attributes: attrs))
            }
        }

        return result
    }

    /// Strip any remaining non-SGR escape sequences (cursor moves, etc.)
    private static func stripNonSGR(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"\x1b\[[^m]*[A-LOT-Za-z]"#) else { return text }
        let nsText = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: nsText.length), withTemplate: "")
    }

    private static func standardColor(_ index: Int, bright: Bool) -> NSColor {
        let colors: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0),         // black
            (0.8, 0.2, 0.2),   // red
            (0.2, 0.8, 0.2),   // green
            (0.8, 0.8, 0.2),   // yellow
            (0.3, 0.5, 0.9),   // blue
            (0.8, 0.3, 0.8),   // magenta
            (0.2, 0.8, 0.8),   // cyan
            (0.8, 0.8, 0.8),   // white
        ]
        let brightColors: [(CGFloat, CGFloat, CGFloat)] = [
            (0.5, 0.5, 0.5),   // bright black
            (1.0, 0.3, 0.3),   // bright red
            (0.3, 1.0, 0.3),   // bright green
            (1.0, 1.0, 0.3),   // bright yellow
            (0.4, 0.6, 1.0),   // bright blue
            (1.0, 0.4, 1.0),   // bright magenta
            (0.3, 1.0, 1.0),   // bright cyan
            (1.0, 1.0, 1.0),   // bright white
        ]
        guard index >= 0 && index < 8 else { return .labelColor }
        let (r, g, b) = bright ? brightColors[index] : colors[index]
        return NSColor(red: r, green: g, blue: b, alpha: 1)
    }

    private static func ansi256Color(_ index: Int) -> NSColor {
        if index < 8 { return standardColor(index, bright: false) }
        if index < 16 { return standardColor(index - 8, bright: true) }
        if index < 232 {
            // 6x6x6 color cube
            let adjusted = index - 16
            let r = CGFloat(adjusted / 36) / 5.0
            let g = CGFloat((adjusted / 6) % 6) / 5.0
            let b = CGFloat(adjusted % 6) / 5.0
            return NSColor(red: r, green: g, blue: b, alpha: 1)
        }
        // Grayscale ramp
        let gray = CGFloat(index - 232) / 23.0
        return NSColor(white: gray, alpha: 1)
    }
}

// MARK: - Attributed Text View (NSViewRepresentable)

private struct AttributedTextView: NSViewRepresentable {
    let attributedString: NSAttributedString

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithAttributedString: attributedString)
        field.isEditable = false
        field.isSelectable = false
        field.isBordered = false
        field.backgroundColor = .clear
        field.lineBreakMode = .byTruncatingTail
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        nsView.attributedStringValue = attributedString
    }
}
