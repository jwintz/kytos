import SwiftUI
import SwiftTerm

struct KytosSettingsView: View {
    @State private var settings = KytosSettings.shared
    
    var body: some View {
        Form {
            Section(header: Text("Display")) {
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
                        #if os(macOS)
                        .font(Font.custom(settings.fontFamily, size: settings.fontSize))
                        #else
                        .font(Font.custom(settings.fontFamily, size: settings.fontSize))
                        #endif
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(8)
                }
                .padding(.vertical, 4)
                
                Picker("Cursor Shape", selection: $settings.cursorStyle) {
                    Text("Block").tag(CursorStyle.steadyBlock)
                    Text("Underline").tag(CursorStyle.steadyUnderline)
                    Text("Vertical Bar").tag(CursorStyle.steadyBar)
                }
                
                Toggle("Cursor Blink", isOn: $settings.cursorBlink)
            }
            
            Section(header: Text("Shell Integration")) {
                #if os(macOS)
                Picker("Default Shell", selection: $settings.shellChoice) {
                    Text("Embedded mksh").tag(KytosSettings.ShellChoice.embeddedMksh)
                    Text("System Default").tag(KytosSettings.ShellChoice.systemShell)
                }
                Text("Changes apply to new terminal sessions.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                #else
                Picker("Default Shell", selection: $settings.shellChoice) {
                    Text("Embedded mksh").tag(KytosSettings.ShellChoice.embeddedMksh)
                }
                .disabled(true)
                
                Text("Only the embedded mksh is supported on iOS.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                #endif
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
