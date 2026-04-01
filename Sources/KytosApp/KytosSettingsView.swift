import SwiftUI
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
        #if os(macOS)
        .frame(width: 450)
        #endif
    }
}

private struct KytosTerminalSettingsTab: View {
    @State private var settings = KytosSettings.shared
    @State private var monoFonts: [String] = []

    var body: some View {
        Form {
            Section("Font") {
                Picker("Family", selection: $settings.fontFamily) {
                    ForEach(monoFonts, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 6...24, step: 1)
                    Text("\(Int(settings.fontSize)) pt")
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
                Picker("Cursor", selection: $settings.cursorShape) {
                    ForEach(KytosCursorShape.allCases, id: \.rawValue) { shape in
                        Text(shape.rawValue).tag(shape.rawValue)
                    }
                }
            }

            Section("Color Scheme") {
                Picker("Scheme", selection: $settings.colorSchemeName) {
                    ForEach(KytosColorScheme.allCases, id: \.rawValue) { scheme in
                        Text(scheme.rawValue).tag(scheme.rawValue)
                    }
                }
                .onChange(of: settings.colorSchemeName) { _, newValue in
                    if let scheme = KytosColorScheme(rawValue: newValue) {
                        KytosTerminalPalette.shared.applyScheme(scheme)
                    }
                }
            }

            Section("User Interface") {
                HStack {
                    Text("Horizontal Margins")
                    Slider(value: $settings.horizontalMargin, in: 0...32, step: 2)
                    Text("\(Int(settings.horizontalMargin)) px")
                        .frame(width: 40, alignment: .trailing)
                }
                HStack {
                    Text("Inspector Refresh")
                    Slider(value: $settings.inspectorRefreshInterval, in: 0.5...10, step: 0.5)
                    Text(String(format: "%.1fs", settings.inspectorRefreshInterval))
                        .frame(width: 40, alignment: .trailing)
                }
                Toggle("Focus Follows Mouse", isOn: $settings.focusFollowsMouse)
                    .help("Automatically focus a split pane when the mouse enters it")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            monoFonts = KytosSettings.monospacedFontFamilies
            if !monoFonts.contains(settings.fontFamily) {
                monoFonts.insert(settings.fontFamily, at: 0)
            }
        }
    }
}
