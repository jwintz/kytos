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
    public static let userDefaultsKey = "KytosWidgetSnapshot"
    public static let appGroupID = "group.me.jwintz.Kytos"

    public let date: Date
    public let windows: [KytosWidgetWindow]
    public var totalTerminals: Int { windows.reduce(0) { $0 + $1.terminalCount } }

    public init(date: Date, windows: [KytosWidgetWindow]) {
        self.date = date
        self.windows = windows
    }

    public static func read() -> KytosWidgetSnapshot? {
        guard let defaults = UserDefaults(suiteName: appGroupID),
              let data = defaults.data(forKey: userDefaultsKey),
              let snapshot = try? JSONDecoder().decode(KytosWidgetSnapshot.self, from: data)
        else { return nil }
        return snapshot
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
