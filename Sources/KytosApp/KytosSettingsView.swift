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
        .frame(width: 450)
    }
}

private struct KytosTerminalSettingsTab: View {
    @State private var settings = KytosSettings.shared

    var body: some View {
        Form {
            Section("Terminal Configuration") {
                Button("Open Ghostty Config") {
                    let configPath = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent(".config/ghostty/config")
                    // Create config dir if needed
                    let dir = configPath.deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    // Create empty config if it doesn't exist
                    if !FileManager.default.fileExists(atPath: configPath.path) {
                        FileManager.default.createFile(atPath: configPath.path, contents: "# Ghostty configuration\n# See: https://ghostty.org/docs/config\n".data(using: .utf8))
                    }
                    NSWorkspace.shared.open(configPath)
                }
                .help("Font, colors, cursor, and all terminal settings are configured in ~/.config/ghostty/config")

                Text("Terminal appearance is managed by Ghostty's configuration file.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("User Interface") {
                HStack {
                    Text("Horizontal Margins")
                    Slider(value: $settings.horizontalMargin, in: 0...32, step: 2)
                    Text("\(Int(settings.horizontalMargin)) px")
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }
        .formStyle(.grouped)
    }
}
