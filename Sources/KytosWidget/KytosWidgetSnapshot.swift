// KytosWidgetSnapshot.swift — shared data model between app and widget targets
// Linked into: Kytos-macOS, Kytos-iOS, Kytos-Widget-macOS, Kytos-Widget-iOS

import Foundation

public struct KytosWidgetTerminal: Codable, Identifiable {
    public let id: UUID
    public let process: String
}

public struct KytosWidgetWindow: Codable, Identifiable {
    public let id: UUID
    public let name: String
    public let terminals: [KytosWidgetTerminal]
    public var terminalCount: Int { terminals.count }
    public var topProcess: String? { terminals.first?.process }
}

public struct KytosWidgetSnapshot: Codable {
    public let date: Date
    public let windows: [KytosWidgetWindow]
    public var totalTerminals: Int { windows.reduce(0) { $0 + $1.terminalCount } }

    public init(date: Date, windows: [KytosWidgetWindow]) {
        self.date = date
        self.windows = windows
    }

    /// Widget container path where the sandboxed widget can read.
    /// The unsandboxed main app writes here directly; the sandboxed widget
    /// reads from its own container via the standard Application Support API.
    private static let widgetBundleID = "me.jwintz.Kytos.KytosWidget"

    /// URL used by the main app (unsandboxed) to write into the widget's container.
    public static var appWriteURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/Kytos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    /// URL used by the widget (sandboxed) — resolves to its own container automatically.
    private static var widgetReadURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kytos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    public static func read() -> KytosWidgetSnapshot? {
        guard let data = try? Data(contentsOf: widgetReadURL),
              let snapshot = try? JSONDecoder().decode(KytosWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
    }

    public static func write(_ snapshot: KytosWidgetSnapshot) {
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: appWriteURL, options: .atomic)
        }
    }

    public static func placeholder() -> KytosWidgetSnapshot {
        KytosWidgetSnapshot(
            date: .now,
            windows: [
                KytosWidgetWindow(id: UUID(), name: "main", terminals: [
                    KytosWidgetTerminal(id: UUID(), process: "zsh"),
                    KytosWidgetTerminal(id: UUID(), process: "vim"),
                ]),
                KytosWidgetWindow(id: UUID(), name: "server", terminals: [
                    KytosWidgetTerminal(id: UUID(), process: "python"),
                ]),
            ]
        )
    }
}
