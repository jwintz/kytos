import SwiftUI
import Observation
import AppKit

/// Kytos-specific UI preferences. Terminal font/color/cursor settings are now
/// managed via `~/.config/ghostty/config`.
@Observable
@MainActor
public final class KytosSettings {
    public static let shared = KytosSettings()

    private let horizontalMarginKey = "kytos_horizontalMargin"

    public var horizontalMargin: CGFloat {
        didSet { UserDefaults.standard.set(horizontalMargin, forKey: horizontalMarginKey) }
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            horizontalMarginKey: 0.0
        ])
        self.horizontalMargin = CGFloat(defaults.double(forKey: horizontalMarginKey))
    }
}
