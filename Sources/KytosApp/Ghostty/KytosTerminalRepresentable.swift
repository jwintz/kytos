import SwiftUI
import GhosttyKit

/// SwiftUI bridge for `KytosGhosttyView`. Reuses existing views from the registry
/// to prevent split creation from resetting terminal sessions.
struct KytosTerminalRepresentable: NSViewRepresentable {
    let terminalID: UUID
    var initialPwd: String?

    func makeNSView(context: Context) -> KytosGhosttyView {
        // Reuse existing view if available (prevents reset on split tree mutations)
        if let existing = KytosGhosttyView.view(for: terminalID) {
            return existing
        }
        let view = KytosGhosttyView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoresizingMask = [.width, .height]
        view.paneID = terminalID
        view.initialPwd = initialPwd
        // Surface is created in viewDidMoveToWindow when the window is available.
        return view
    }

    func updateNSView(_ nsView: KytosGhosttyView, context: Context) {
        // Ensure paneID stays in sync
        nsView.paneID = terminalID
    }
}
