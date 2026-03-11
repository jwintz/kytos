// KytosProgressBar.swift — Graphical progress bar for terminal commands
// Backported from ghostty's SurfaceProgressBar.swift

import SwiftUI
import GhosttyKit

/// A thin progress bar overlaid on a terminal surface, driven by
/// GHOSTTY_ACTION_PROGRESS_REPORT OSC sequences from the shell.
struct KytosProgressBar: View {
    let state: UInt32  // ghostty_action_progress_report_state_e raw value
    let progress: Int8 // -1 if no progress reported, 0-100 otherwise

    private var color: SwiftUI.Color {
        switch state {
        case GHOSTTY_PROGRESS_STATE_ERROR.rawValue: return .red
        case GHOSTTY_PROGRESS_STATE_PAUSE.rawValue: return .orange
        default: return .accentColor
        }
    }

    private var resolvedProgress: UInt8? {
        if progress >= 0 { return UInt8(progress) }
        if state == GHOSTTY_PROGRESS_STATE_PAUSE.rawValue { return 100 }
        return nil
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                if let pct = resolvedProgress {
                    Rectangle()
                        .fill(color)
                        .frame(
                            width: geometry.size.width * CGFloat(pct) / 100,
                            height: geometry.size.height
                        )
                        .animation(.easeInOut(duration: 0.2), value: pct)
                } else {
                    BouncingBar(color: color)
                }
            }
        }
        .frame(height: 2)
        .clipped()
        .allowsHitTesting(false)
    }
}

private struct BouncingBar: View {
    let color: SwiftUI.Color
    @State private var position: CGFloat = 0

    private let barWidthRatio: CGFloat = 0.25

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(color.opacity(0.3))
                Rectangle()
                    .fill(color)
                    .frame(
                        width: geometry.size.width * barWidthRatio,
                        height: geometry.size.height
                    )
                    .offset(x: position * (geometry.size.width * (1 - barWidthRatio)))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                position = 1
            }
        }
        .onDisappear { position = 0 }
    }
}
