import Observation
import AppKit

/// Kytos-specific UI preferences. Terminal font/color/cursor settings are now
/// managed via `~/.config/ghostty/config`.
@Observable
@MainActor
public final class KytosSettings {
    public static let shared = KytosSettings()

    private let horizontalMarginKey = "kytos_horizontalMargin"
    private let inspectorRefreshKey = "kytos_inspectorRefreshInterval"
    private let focusFollowsMouseKey = "kytos_focusFollowsMouse"

    @ObservationIgnored private var saveWorkItem: DispatchWorkItem?

    public var horizontalMargin: CGFloat {
        didSet { scheduleSave() }
    }

    public var inspectorRefreshInterval: TimeInterval {
        didSet { scheduleSave() }
    }

    public var focusFollowsMouse: Bool {
        didSet { scheduleSave() }
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        saveWorkItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let defaults = UserDefaults.standard
            defaults.set(self.horizontalMargin, forKey: self.horizontalMarginKey)
            defaults.set(self.inspectorRefreshInterval, forKey: self.inspectorRefreshKey)
            defaults.set(self.focusFollowsMouse, forKey: self.focusFollowsMouseKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: saveWorkItem!)
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            horizontalMarginKey: 0.0,
            inspectorRefreshKey: 2.0,
            focusFollowsMouseKey: false,
        ])
        self.horizontalMargin = CGFloat(defaults.double(forKey: horizontalMarginKey))
        self.inspectorRefreshInterval = defaults.double(forKey: inspectorRefreshKey)
        self.focusFollowsMouse = defaults.bool(forKey: focusFollowsMouseKey)
    }
}
