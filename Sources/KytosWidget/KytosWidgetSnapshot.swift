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

    private static let widgetBundleID = "me.jwintz.Kytos.KytosWidget"
    #if os(iOS)
    private static let appGroupID = "group.me.jwintz.Syntropment"
    #else
    private static let appGroupID = "group.me.jwintz.Kytos"
    #endif

    /// Shared URL for widget snapshot data.
    /// - macOS: The unsandboxed main app writes directly into the widget's container.
    ///   The sandboxed widget reads from its own Application Support.
    /// - iOS: Both app and widget use the shared App Group container.
    private static var sharedURL: URL {
        let dir: URL
        #if os(iOS)
        dir = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)!
            .appendingPathComponent("Kytos", isDirectory: true)
        #else
        dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kytos", isDirectory: true)
        #endif
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
    }

    /// URL used by the main app (unsandboxed on macOS) to write widget data.
    public static var appWriteURL: URL {
        #if os(macOS)
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent("Library/Containers/\(widgetBundleID)/Data/Library/Application Support/Kytos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("widget-snapshot.json")
        #else
        return sharedURL
        #endif
    }

    public static func read() -> KytosWidgetSnapshot? {
        guard let data = try? Data(contentsOf: sharedURL),
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
