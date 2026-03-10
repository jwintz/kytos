import SwiftUI
import SwiftTerm
import Observation

import AppKit
public typealias KytosFont = NSFont

@Observable
public final class KytosSettings {
    public static let shared = KytosSettings()
    
    // User Defaults Keys
    private let cursorStyleKey = "kytos_cursorStyle"
    private let cursorBlinkKey = "kytos_cursorBlink"
    private let fontFamilyKey = "kytos_fontFamily"
    private let fontSizeKey = "kytos_fontSize"
    private let shellChoiceKey = "kytos_shellChoice"
    private let horizontalMarginKey = "kytos_horizontalMargin"
    private let ansi256PaletteKey = "kytos_ansi256Palette"
    private let scrollbackSizeKey = "kytos_scrollbackSize"
    
    // We bind properties manually to UserDefaults because @AppStorage isn't easily supported natively inside @Observable classes
    
    public var cursorStyle: CursorStyle {
        didSet { 
            let styleName: String
            switch cursorStyle {
            case .steadyBlock: styleName = "steadyBlock"
            case .steadyUnderline: styleName = "steadyUnderline"
            case .steadyBar: styleName = "steadyBar"
            default: styleName = "steadyBlock"
            }
            UserDefaults.standard.set(styleName, forKey: cursorStyleKey) 
        }
    }
    
    public var cursorBlink: Bool {
        didSet { UserDefaults.standard.set(cursorBlink, forKey: cursorBlinkKey) }
    }
    
    public var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: fontFamilyKey) }
    }
    
    public var fontSize: CGFloat {
        didSet { UserDefaults.standard.set(fontSize, forKey: fontSizeKey) }
    }
    
    public enum ShellChoice: String, CaseIterable, Identifiable {
        case systemShell = "System Shell"
        public var id: String { rawValue }
    }
    
    public var shellChoice: ShellChoice {
        didSet { UserDefaults.standard.set(shellChoice.rawValue, forKey: shellChoiceKey) }
    }

    public var horizontalMargin: CGFloat {
        didSet { UserDefaults.standard.set(horizontalMargin, forKey: horizontalMarginKey) }
    }

    public var ansi256Palette: Ansi256PaletteStrategy {
        didSet {
            UserDefaults.standard.set(
                ansi256Palette == .base16Lab ? "base16Lab" : "xterm",
                forKey: ansi256PaletteKey)
        }
    }

    public var scrollbackSize: Int {
        didSet { UserDefaults.standard.set(scrollbackSize, forKey: scrollbackSizeKey) }
    }
    
    private init() {
        let defaults = UserDefaults.standard

        // Defaults
        let defaultShell = ShellChoice.systemShell.rawValue
        defaults.register(defaults: [
            cursorStyleKey: "steadyBlock",
            cursorBlinkKey: false,
            fontFamilyKey: "SF Mono",
            fontSizeKey: 12.0,
            shellChoiceKey: defaultShell,
            horizontalMarginKey: 0.0,
            ansi256PaletteKey: "xterm",
            scrollbackSizeKey: 500
        ])

        let styleRaw = defaults.string(forKey: cursorStyleKey) ?? "steadyBlock"
        switch styleRaw {
        case "steadyBlock": self.cursorStyle = .steadyBlock
        case "steadyUnderline": self.cursorStyle = .steadyUnderline
        case "steadyBar": self.cursorStyle = .steadyBar
        default: self.cursorStyle = .steadyBlock
        }
        self.cursorBlink = defaults.bool(forKey: cursorBlinkKey)
        self.fontFamily = defaults.string(forKey: fontFamilyKey) ?? "SF Mono"
        self.fontSize = CGFloat(defaults.double(forKey: fontSizeKey))

        if let shellRaw = defaults.string(forKey: shellChoiceKey), let choice = ShellChoice(rawValue: shellRaw) {
            self.shellChoice = choice
        } else {
            self.shellChoice = .systemShell
        }

        self.horizontalMargin = CGFloat(defaults.double(forKey: horizontalMarginKey))
        self.ansi256Palette = defaults.string(forKey: ansi256PaletteKey) == "base16Lab" ? .base16Lab : .xterm

        let rawScrollback = defaults.integer(forKey: scrollbackSizeKey)
        self.scrollbackSize = rawScrollback > 0 ? rawScrollback : 500

        print("[KytosDebug][Settings] init — cursorStyle=\(styleRaw), cursorBlink=\(cursorBlink), fontFamily=\(fontFamily), fontSize=\(fontSize), shellChoice=\(shellChoice.rawValue)")
        print("[KytosDebug][Settings] raw UserDefaults — cursorStyle=\(defaults.string(forKey: cursorStyleKey) ?? "nil"), fontFamily=\(defaults.string(forKey: fontFamilyKey) ?? "nil"), fontSize=\(defaults.double(forKey: fontSizeKey)), shellChoice=\(defaults.string(forKey: shellChoiceKey) ?? "nil")")
    }
    
    public func resolvedCommandLine() -> [String] {
        switch shellChoice {
        case .systemShell:  return [ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"]
        }
    }

    public var nsFont: KytosFont {
        let font: KytosFont
        if let f = NSFontManager.shared.font(withFamily: fontFamily, traits: [], weight: 5, size: fontSize) {
            font = f
        } else {
            font = NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        }
        print("[KytosDebug][Font] Resolved '\(fontFamily)' to: \(font.fontName) (displayName: \(font.displayName ?? "nil"))")
        return font
    }
    public static let availableFonts: [String] = {
        let manager = NSFontManager.shared
        let allFamilies = manager.availableFontFamilies
        var monospaced: [String] = []
        for family in allFamilies {
            if let font = NSFont(name: family, size: 12), font.isFixedPitch {
                monospaced.append(family)
            }
        }
        if !monospaced.contains("SF Mono") { monospaced.insert("SF Mono", at: 0) }
        return monospaced
    }()
}
