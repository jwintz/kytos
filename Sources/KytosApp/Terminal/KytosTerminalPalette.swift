// KytosTerminalPalette.swift — Appearance-aware terminal color palette

import AppKit
import Observation
@preconcurrency import SwiftTerm

/// Available color scheme presets.
enum KytosColorScheme: String, CaseIterable, Sendable {
    case `default` = "Default"
    case nano = "Nano"

    var lightScheme: ITermColorScheme {
        switch self {
        case .default: return .defaultLight
        case .nano: return .nanoLight
        }
    }

    var darkScheme: ITermColorScheme {
        switch self {
        case .default: return .defaultDark
        case .nano: return .nanoDark
        }
    }
}

/// Appearance-aware terminal color palette with light/dark variants.
@MainActor
@Observable
final class KytosTerminalPalette {
    static let shared = KytosTerminalPalette()

    private(set) var light: ITermColorScheme
    private(set) var dark: ITermColorScheme
    private(set) var isDark: Bool = false
    private(set) var version: Int = 0

    @ObservationIgnored nonisolated(unsafe) private var appearanceObserver: NSObjectProtocol?

    private init() {
        let scheme = KytosColorScheme(rawValue: KytosSettings.shared.colorSchemeName) ?? .default
        self.light = scheme.lightScheme
        self.dark = scheme.darkScheme
        loadCustomThemes(for: scheme)
        setupAppearanceObserver()
    }

    deinit {
        if let observer = appearanceObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Public API

    var ansiColors: [String] { isDark ? dark.ansiColors : light.ansiColors }
    var foreground: String { isDark ? dark.foreground : light.foreground }
    var background: String { isDark ? dark.background : light.background }
    var cursor: String { isDark ? dark.cursor : light.cursor }

    func setAppearance(isDark: Bool) {
        guard self.isDark != isDark else { return }
        self.isDark = isDark
        version += 1
    }

    func applyScheme(_ scheme: KytosColorScheme) {
        self.light = scheme.lightScheme
        self.dark = scheme.darkScheme
        loadCustomThemes(for: scheme)
        version += 1
    }

    // MARK: - Custom Theme Loading

    /// Attempt to load .itermcolors overrides from ~/.config/kytos/.
    private func loadCustomThemes(for scheme: KytosColorScheme) {
        let prefix: String
        switch scheme {
        case .nano: prefix = "nano"
        case .default: prefix = "default"
        }

        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return }
        let fm = FileManager.default
        let searchPaths = [
            (home as NSString).appendingPathComponent(".config/kytos"),
            (home as NSString).appendingPathComponent("Library/Application Support/kytos"),
        ]

        for path in searchPaths {
            let darkURL = URL(fileURLWithPath: (path as NSString).appendingPathComponent("\(prefix)-dark.itermcolors"))
            let lightURL = URL(fileURLWithPath: (path as NSString).appendingPathComponent("\(prefix)-light.itermcolors"))
            if fm.fileExists(atPath: darkURL.path), let parsed = ITermColorsParser.parse(url: darkURL) {
                self.dark = parsed
            }
            if fm.fileExists(atPath: lightURL.path), let parsed = ITermColorsParser.parse(url: lightURL) {
                self.light = parsed
            }
        }
    }

    // MARK: - Appearance Observer

    private func setupAppearanceObserver() {
        appearanceObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                self.setAppearance(isDark: dark)
            }
        }
    }
}

// MARK: - NSColor Hex Conversion

extension NSColor {
    static func fromHex(_ hex: String) -> NSColor? {
        let trimmed = hex.trimmingCharacters(in: .whitespaces)
        let hexString = trimmed.hasPrefix("#") ? String(trimmed.dropFirst()) : trimmed
        guard hexString.count == 6 else { return nil }
        var rgb: UInt64 = 0
        Scanner(string: hexString).scanHexInt64(&rgb)
        let r = CGFloat((rgb >> 16) & 0xFF) / 255.0
        let g = CGFloat((rgb >> 8) & 0xFF) / 255.0
        let b = CGFloat(rgb & 0xFF) / 255.0
        return NSColor(red: r, green: g, blue: b, alpha: 1.0)
    }

    func toSwiftTermColor() -> SwiftTerm.Color? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let converted = self.usingColorSpace(.sRGB) ?? self
        converted.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SwiftTerm.Color(
            red: UInt16(r * 65535),
            green: UInt16(g * 65535),
            blue: UInt16(b * 65535)
        )
    }
}

// MARK: - TerminalView Palette Application

extension KytosTerminalView {
    func applyPalette(_ palette: KytosTerminalPalette) {
        if let fg = NSColor.fromHex(palette.foreground) {
            self.nativeForegroundColor = fg
        }
        if let cursorColor = NSColor.fromHex(palette.cursor) {
            self.caretColor = cursorColor
        }

        // Translucent background
        self.nativeBackgroundColor = NSColor.clear
        self.layer?.backgroundColor = NSColor.clear.cgColor
        self.layer?.isOpaque = false

        let swiftTermColors: [SwiftTerm.Color] = palette.ansiColors.compactMap { hex in
            guard let ns = NSColor.fromHex(hex) else { return nil }
            return ns.toSwiftTermColor()
        }
        if swiftTermColors.count == 16 {
            self.installColors(swiftTermColors)
        }
    }
}
