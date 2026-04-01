import Observation
import AppKit

/// Kytos-specific UI preferences.
@Observable
@MainActor
public final class KytosSettings {
    public static let shared = KytosSettings()

    private let horizontalMarginKey = "kytos_horizontalMargin"
    private let inspectorRefreshKey = "kytos_inspectorRefreshInterval"
    private let focusFollowsMouseKey = "kytos_focusFollowsMouse"
    private let fontFamilyKey = "kytos_fontFamily"
    private let fontSizeKey = "kytos_fontSize"
    private let colorSchemeKey = "kytos_colorScheme"
    private let cursorShapeKey = "kytos_cursorShape"

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

    public var fontFamily: String {
        didSet { scheduleSave() }
    }

    public var fontSize: CGFloat {
        didSet { scheduleSave() }
    }

    public var colorSchemeName: String {
        didSet { scheduleSave() }
    }

    public var cursorShape: String {
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
            defaults.set(self.fontFamily, forKey: self.fontFamilyKey)
            defaults.set(self.fontSize, forKey: self.fontSizeKey)
            defaults.set(self.colorSchemeName, forKey: self.colorSchemeKey)
            defaults.set(self.cursorShape, forKey: self.cursorShapeKey)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: saveWorkItem!)
    }

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            horizontalMarginKey: 0.0,
            inspectorRefreshKey: 2.0,
            focusFollowsMouseKey: false,
            fontFamilyKey: KytosTerminalDefaults.fontFamily,
            fontSizeKey: KytosTerminalDefaults.fontSize,
            colorSchemeKey: KytosColorScheme.default.rawValue,
            cursorShapeKey: KytosCursorShape.bar.rawValue,
        ])
        self.horizontalMargin = CGFloat(defaults.double(forKey: horizontalMarginKey))
        self.inspectorRefreshInterval = defaults.double(forKey: inspectorRefreshKey)
        self.focusFollowsMouse = defaults.bool(forKey: focusFollowsMouseKey)
        self.fontFamily = defaults.string(forKey: fontFamilyKey) ?? KytosTerminalDefaults.fontFamily
        let savedFontSize = CGFloat(defaults.double(forKey: fontSizeKey))
        self.fontSize = savedFontSize < 6 ? KytosTerminalDefaults.fontSize : savedFontSize
        self.colorSchemeName = defaults.string(forKey: colorSchemeKey) ?? KytosColorScheme.default.rawValue
        self.cursorShape = defaults.string(forKey: cursorShapeKey) ?? KytosCursorShape.bar.rawValue
    }

    /// Available monospaced font families on the system.
    static var monospacedFontFamilies: [String] {
        NSFontManager.shared.availableFontFamilies.filter { family in
            guard let font = NSFont(name: family, size: 12) else { return false }
            return font.isFixedPitch
        }.sorted()
    }
}
