// KytosDragDrop.swift — Split pane drag-and-drop support

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Drop Zone

public enum KytosSplitDropZone: String, CaseIterable, Sendable {
    case top, bottom, left, right

    /// Determine which zone a point falls in within a rect, using triangular hit testing.
    static func zone(for point: CGPoint, in size: CGSize) -> KytosSplitDropZone {
        let cx = size.width / 2
        let cy = size.height / 2
        let dx = point.x - cx
        let dy = point.y - cy

        // Normalize to unit square
        let nx = dx / cx
        let ny = dy / cy

        if abs(nx) > abs(ny) {
            return nx > 0 ? .right : .left
        } else {
            return ny > 0 ? .bottom : .top
        }
    }
}

// MARK: - UTType for Pane ID

extension UTType {
    static let kytosPaneID = UTType(exportedAs: "me.jwintz.kytos.pane-id")
}

// MARK: - Transferable Pane ID

struct KytosPaneTransfer: Codable, Transferable {
    let paneID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kytosPaneID)
    }
}

// MARK: - Drop Zone Overlay

struct KytosPaneDropOverlay: View {
    let isTargeted: Bool
    let activeZone: KytosSplitDropZone?

    var body: some View {
        GeometryReader { geo in
            if isTargeted, let zone = activeZone {
                zoneHighlight(zone: zone, size: geo.size)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func zoneHighlight(zone: KytosSplitDropZone, size: CGSize) -> some View {
        let halfW = size.width / 2
        let halfH = size.height / 2

        Rectangle()
            .fill(Color.accentColor.opacity(0.25))
            .border(Color.accentColor.opacity(0.6), width: 2)
            .frame(
                width: (zone == .left || zone == .right) ? halfW : size.width,
                height: (zone == .top || zone == .bottom) ? halfH : size.height
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity,
                   alignment: zoneAlignment(zone))
    }

    private func zoneAlignment(_ zone: KytosSplitDropZone) -> Alignment {
        switch zone {
        case .top: return .top
        case .bottom: return .bottom
        case .left: return .leading
        case .right: return .trailing
        }
    }
}

// MARK: - Drag Handle View

struct KytosPaneDragHandle: View {
    let paneID: UUID
    @State private var isHovering = false

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(4)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(isHovering ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: isHovering)
            .draggable(KytosPaneTransfer(paneID: paneID))
            .onHover { isHovering = $0 }
            .help("Drag to reorder pane")
    }
}
