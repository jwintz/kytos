// KytosTerminalRepresentable.swift — SwiftUI bridge for KytosTerminalView

import SwiftUI
@preconcurrency import SwiftTerm

/// SwiftUI NSViewRepresentable that creates and manages a KytosTerminalView.
/// Reuses existing views from the registry to prevent split creation from
/// resetting terminal sessions.
struct KytosTerminalRepresentable: NSViewRepresentable {
    let terminalID: UUID
    var initialPwd: String?
    var fontFamily: String
    var fontSize: CGFloat
    var cursorShape: String
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> KytosTerminalView {
        let palette = KytosTerminalPalette.shared
        palette.setAppearance(isDark: colorScheme == .dark)

        if let existing = KytosTerminalView.view(for: terminalID) {
            existing.processDelegate = context.coordinator
            context.coordinator.terminalView = existing
            context.coordinator.lastPaletteVersion = palette.version
            context.coordinator.lastFontFamily = fontFamily
            context.coordinator.lastFontSize = fontSize
            context.coordinator.lastCursorShape = cursorShape
            return existing
        }

        let view = KytosTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.autoresizingMask = [.width, .height]
        view.paneID = terminalID
        view.initialPwd = initialPwd
        view.processDelegate = context.coordinator

        KytosTerminalView.viewRegistry[terminalID] = view

        view.applyPalette(palette)
        view.applySettingsFont()
        view.startTerminalProcess()

        context.coordinator.terminalView = view
        context.coordinator.lastPaletteVersion = palette.version
        context.coordinator.lastFontFamily = fontFamily
        context.coordinator.lastFontSize = fontSize
        context.coordinator.lastCursorShape = cursorShape

        return view
    }

    func updateNSView(_ nsView: KytosTerminalView, context: Context) {
        nsView.paneID = terminalID

        let palette = KytosTerminalPalette.shared
        let systemIsDark = colorScheme == .dark
        if palette.isDark != systemIsDark {
            palette.setAppearance(isDark: systemIsDark)
        }

        let currentVersion = palette.version
        if currentVersion != context.coordinator.lastPaletteVersion {
            context.coordinator.lastPaletteVersion = currentVersion
            nsView.applyPalette(palette)
        }

        if fontFamily != context.coordinator.lastFontFamily
            || fontSize != context.coordinator.lastFontSize {
            context.coordinator.lastFontFamily = fontFamily
            context.coordinator.lastFontSize = fontSize
            nsView.applySettingsFont()
        }

        if cursorShape != context.coordinator.lastCursorShape {
            context.coordinator.lastCursorShape = cursorShape
            nsView.applyCursorShape()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var terminalView: KytosTerminalView?
        var lastPaletteVersion: Int = -1
        var lastFontFamily: String = ""
        var lastFontSize: CGFloat = 0
        var lastCursorShape: String = ""

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
        }

        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            MainActor.assumeIsolated {
                guard let tv = self.terminalView, let paneID = tv.paneID else { return }
                tv.title = title
                NotificationCenter.default.post(
                    name: .kytosTerminalSetTitle,
                    object: tv,
                    userInfo: ["title": title, "paneID": paneID]
                )
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {
            MainActor.assumeIsolated {
                guard let tv = self.terminalView, let paneID = tv.paneID else { return }
                let dir: String
                if let raw = directory, raw.hasPrefix("file://"), let url = URL(string: raw) {
                    dir = url.path
                } else {
                    dir = directory ?? ""
                }
                tv.pwd = dir
                NotificationCenter.default.post(
                    name: .kytosTerminalPwd,
                    object: tv,
                    userInfo: ["pwd": dir, "paneID": paneID]
                )
            }
        }

        nonisolated func processTerminated(source: SwiftTerm.TerminalView, exitCode: Int32?) {
        }
    }
}
