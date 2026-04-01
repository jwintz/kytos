// ITermColorsParser.swift — Parser for iTerm2 color scheme files (.itermcolors)

import Foundation

/// Represents a parsed iTerm2 color scheme.
public struct ITermColorScheme: Sendable {
    public var ansiColors: [String]
    public var foreground: String
    public var background: String
    public var cursor: String
    public var selection: String?
    public var bold: String?

    public init(
        ansiColors: [String],
        foreground: String,
        background: String,
        cursor: String,
        selection: String? = nil,
        bold: String? = nil
    ) {
        self.ansiColors = ansiColors
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.selection = selection
        self.bold = bold
    }
}

/// Parser for .itermcolors XML plist files.
public enum ITermColorsParser {

    public static func parse(data: Data) -> ITermColorScheme? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = plist as? [String: [String: Any]] else {
            return nil
        }

        var ansiColors: [String] = []
        for i in 0..<16 {
            if let colorDict = dict["Ansi \(i) Color"],
               let hex = colorFromDict(colorDict) {
                ansiColors.append(hex)
            } else {
                ansiColors.append(i < 8 ? "#000000" : "#808080")
            }
        }

        guard ansiColors.count == 16 else { return nil }

        guard let foregroundDict = dict["Foreground Color"],
              let foreground = colorFromDict(foregroundDict),
              let backgroundDict = dict["Background Color"],
              let background = colorFromDict(backgroundDict),
              let cursorDict = dict["Cursor Color"],
              let cursor = colorFromDict(cursorDict) else {
            return nil
        }

        let selection = dict["Selection Color"].flatMap { colorFromDict($0) }
        let bold = dict["Bold Color"].flatMap { colorFromDict($0) }

        return ITermColorScheme(
            ansiColors: ansiColors,
            foreground: foreground,
            background: background,
            cursor: cursor,
            selection: selection,
            bold: bold
        )
    }

    public static func parse(url: URL) -> ITermColorScheme? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(data: data)
    }

    private static func colorFromDict(_ dict: [String: Any]) -> String? {
        let red: Double
        if let v = dict["Red Component"] as? CGFloat { red = Double(v) }
        else if let v = dict["Red Component"] as? Double { red = v }
        else { return nil }

        let green: Double
        if let v = dict["Green Component"] as? CGFloat { green = Double(v) }
        else if let v = dict["Green Component"] as? Double { green = v }
        else { return nil }

        let blue: Double
        if let v = dict["Blue Component"] as? CGFloat { blue = Double(v) }
        else if let v = dict["Blue Component"] as? Double { blue = v }
        else { return nil }

        let r = Int(round(red * 255))
        let g = Int(round(green * 255))
        let b = Int(round(blue * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - Predefined Schemes

public extension ITermColorScheme {
    /// Nano dark theme
    static let nanoDark = ITermColorScheme(
        ansiColors: [
            "#1E1E1E", "#F38BA8", "#DCD3F8", "#EDE8FC",
            "#A68AF9", "#DCD3F8", "#EDE8FC", "#FFFFFF",
            "#808080", "#F38BA8", "#DCD3F8", "#EDE8FC",
            "#A68AF9", "#DCD3F8", "#EDE8FC", "#FFFFFF"
        ],
        foreground: "#FFFFFF",
        background: "#1E1E1E",
        cursor: "#A68AF9",
        selection: "#655594",
        bold: "#FFFFFF"
    )

    /// Nano light theme
    static let nanoLight = ITermColorScheme(
        ansiColors: [
            "#FFFFFF", "#730C29", "#321685", "#240E66",
            "#A68AF7", "#321685", "#240E66", "#000000",
            "#808080", "#730C29", "#321685", "#240E66",
            "#A68AF7", "#321685", "#240E66", "#000000"
        ],
        foreground: "#000000",
        background: "#FFFFFF",
        cursor: "#A68AF7",
        selection: "#C5BEDA",
        bold: "#000000"
    )

    /// Default dark theme (Zinc/Violet)
    static let defaultDark = ITermColorScheme(
        ansiColors: [
            "#27272A", "#EF5350", "#66BB6A", "#FFEE58",
            "#42A5F5", "#AB47BC", "#26C6DA", "#F4F4F5",
            "#52525B", "#F87171", "#4ADE80", "#FDE047",
            "#60A5FA", "#C084FC", "#22D3EE", "#FFFFFF"
        ],
        foreground: "#F4F4F5",
        background: "#18181B",
        cursor: "#A58AF9",
        selection: "#655594",
        bold: "#FFFFFF"
    )

    /// Default light theme (Zinc/Violet)
    static let defaultLight = ITermColorScheme(
        ansiColors: [
            "#FAFAFA", "#D32F2F", "#2E7D32", "#F57F17",
            "#1976D2", "#7B1FA2", "#00838F", "#18181B",
            "#A1A1AA", "#EF5350", "#66BB6A", "#FFA726",
            "#42A5F5", "#AB47BC", "#26C6DA", "#000000"
        ],
        foreground: "#18181B",
        background: "#FFFFFF",
        cursor: "#A58AF9",
        selection: "#C5BEDA",
        bold: "#000000"
    )
}
