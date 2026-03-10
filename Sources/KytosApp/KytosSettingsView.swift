import SwiftUI
import SwiftTerm
import KelyphosKit

struct KytosSettingsWindowView: View {
    let shellState: KelyphosShellState

    var body: some View {
        TabView {
            KytosTerminalSettingsTab()
                .tabItem { Label("Terminal", systemImage: "terminal") }
            KelyphosSettingsView(state: shellState)
                .tabItem { Label("Appearance", systemImage: "paintbrush") }
        }
        .frame(width: 450)
    }
}

private struct KytosTerminalSettingsTab: View {
    @State private var settings = KytosSettings.shared

    var body: some View {
        Form {
            Section("User Interface") {
                Picker("Font Family", selection: $settings.fontFamily) {
                    ForEach(KytosSettings.availableFonts, id: \.self) { fontName in
                        Text(fontName)
                            .font(.custom(fontName, size: 14))
                            .tag(fontName)
                    }
                }

                HStack {
                    Text("Font Size")
                    Slider(value: $settings.fontSize, in: 8...36, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .frame(width: 40, alignment: .trailing)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("The quick brown fox jumps over the lazy dog.")
                        .font(Font(settings.nsFont))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.vertical, 4)

                Picker("Cursor Shape", selection: $settings.cursorStyle) {
                    Text("Block").tag(CursorStyle.steadyBlock)
                    Text("Underline").tag(CursorStyle.steadyUnderline)
                    Text("Vertical Bar").tag(CursorStyle.steadyBar)
                }

                Toggle("Cursor Blink", isOn: $settings.cursorBlink)

                Picker("256-Color Palette", selection: $settings.ansi256Palette) {
                    Text("Standard (xterm)").tag(Ansi256PaletteStrategy.xterm)
                    Text("Perceptual (base16Lab)").tag(Ansi256PaletteStrategy.base16Lab)
                }
                .help("base16Lab maps the 240 xterm colors to perceptually match your 16-color palette. Recommended with custom color schemes.")

                HStack {
                    Text("Horizontal Margins")
                    Slider(value: $settings.horizontalMargin, in: 0...32, step: 2)
                    Text("\(Int(settings.horizontalMargin)) px")
                        .frame(width: 40, alignment: .trailing)
                }

                HStack {
                    Text("Scrollback Lines")
                    Slider(value: Binding(
                        get: { Double(settings.scrollbackSize) },
                        set: { settings.scrollbackSize = Int($0) }
                    ), in: 100...10000, step: 100)
                    Text("\(settings.scrollbackSize)")
                        .frame(width: 50, alignment: .trailing)
                }
                .help("Number of lines kept in the scrollback buffer. Changes apply to new terminal sessions.")
            }

            Section("Shell") {
                Picker("Default Shell", selection: $settings.shellChoice) {
                    Text("System Default").tag(KytosSettings.ShellChoice.systemShell)
                }
                Text("Changes apply to new terminal sessions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
