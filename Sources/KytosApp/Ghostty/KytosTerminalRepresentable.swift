import SwiftUI
import GhosttyKit

/// SwiftUI bridge for `KytosGhosttyView`. Thin wrapper — no coordinator or streaming logic.
struct KytosTerminalRepresentable: NSViewRepresentable {
    let terminalID: UUID

    func makeNSView(context: Context) -> KytosGhosttyView {
        let view = KytosGhosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoresizingMask = [.width, .height]
        // Surface is created in viewDidMoveToWindow when the window is available.
        return view
    }

    func updateNSView(_ nsView: KytosGhosttyView, context: Context) {
        // Color scheme changes are handled via ghostty config
    }
}
