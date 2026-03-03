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
    }
    
    public var nsFont: KytosFont {
        #if os(macOS)
        return NSFont(name: fontFamily, size: fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #else
        return UIFont(name: fontFamily, size: fontSize) ?? UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        #endif
    }
}
