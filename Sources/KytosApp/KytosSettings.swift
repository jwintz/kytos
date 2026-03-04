import SwiftUI
import SwiftTerm
import Observation

#if os(macOS)
import AppKit
public typealias KytosFont = NSFont
#else
import UIKit
public typealias KytosFont = UIFont
#endif

@Observable
public final class KytosSettings {
    public static let shared = KytosSettings()
    
    // User Defaults Keys
    private let cursorStyleKey = "kytos_cursorStyle"
    private let cursorBlinkKey = "kytos_cursorBlink"
    private let fontFamilyKey = "kytos_fontFamily"
    private let fontSizeKey = "kytos_fontSize"
    private let shellChoiceKey = "kytos_shellChoice"
    
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
        case embeddedMksh = "Embedded mksh"
        case systemShell = "System Shell"
        public var id: String { rawValue }
    }
    
    public var shellChoice: ShellChoice {
        didSet { UserDefaults.standard.set(shellChoice.rawValue, forKey: shellChoiceKey) }
    }
    
    private init() {
        let defaults = UserDefaults.standard

        // Defaults
        defaults.register(defaults: [
            cursorStyleKey: "steadyBlock",
            cursorBlinkKey: false,
            fontFamilyKey: "SF Mono",
            fontSizeKey: 12.0,
            shellChoiceKey: ShellChoice.embeddedMksh.rawValue
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
            self.shellChoice = .embeddedMksh
        }

        print("[KytosDebug][Settings] init — cursorStyle=\(styleRaw), cursorBlink=\(cursorBlink), fontFamily=\(fontFamily), fontSize=\(fontSize), shellChoice=\(shellChoice.rawValue)")
        print("[KytosDebug][Settings] raw UserDefaults — cursorStyle=\(defaults.string(forKey: cursorStyleKey) ?? "nil"), fontFamily=\(defaults.string(forKey: fontFamilyKey) ?? "nil"), fontSize=\(defaults.double(forKey: fontSizeKey)), shellChoice=\(defaults.string(forKey: shellChoiceKey) ?? "nil")")
    }
    
    public var nsFont: KytosFont {
        #if os(macOS)
        return NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #else
        return UIFont(name: fontFamily, size: fontSize) ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #endif
    }
#if os(macOS)
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
#else
    public static let availableFonts: [String] = {
        var monospaced: [String] = []
        for family in UIFont.familyNames {
            if let font = UIFont(name: family, size: 12), font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace) {
                monospaced.append(family)
            }
        }
        if !monospaced.contains("Menlo") { monospaced.insert("Menlo", at: 0) }
        return monospaced
    }()
#endif
}
