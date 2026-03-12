// KytosDragDrop.swift — Split pane drag-and-drop support

import SwiftUI
import AppKit
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

// MARK: - Pasteboard Type for Pane ID

extension NSPasteboard.PasteboardType {
    static let kytosPaneID = NSPasteboard.PasteboardType(UTType.kytosPaneID.identifier)
}

// MARK: - Transferable Pane ID

struct KytosPaneTransfer: Codable, Transferable {
    let paneID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .kytosPaneID)
    }
}

// MARK: - Dragging Pane Preference Key

struct KytosDraggingPaneKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: UUID?
    static func reduce(value: inout UUID?, nextValue: () -> UUID?) {
        value = nextValue() ?? value
    }
}

// MARK: - NSView-based Drag Source (matches Ghostty's SurfaceDragSourceView pattern)

@MainActor
final class KytosPaneDragSourceView: NSView, NSDraggingSource {
    var paneID: UUID?
    var onDragStateChanged: ((Bool) -> Void)?
    private var isDragging = false

    override init(frame: NSRect) {
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        // Don't start drag on single click — wait for drag
        super.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let paneID, !isDragging else { return }
        isDragging = true

        let transfer = KytosPaneTransfer(paneID: paneID)
        guard let data = try? JSONEncoder().encode(transfer) else { return }

        let item = NSDraggingItem(pasteboardWriter: NSPasteboardItem())
        if let pbItem = item.item as? NSPasteboardItem {
            pbItem.setData(data, forType: .kytosPaneID)
        }

        // Use a small drag image
        let size = NSSize(width: 24, height: 16)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.controlAccentColor.withAlphaComponent(0.5).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            return true
        }
        item.setDraggingFrame(NSRect(origin: .zero, size: size), contents: image)

        onDragStateChanged?(true)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    // NSDraggingSource
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        onDragStateChanged?(false)
    }
}

struct KytosPaneDragSourceRepresentable: NSViewRepresentable {
    let paneID: UUID
    @Binding var isDragging: Bool

    func makeNSView(context: Context) -> KytosPaneDragSourceView {
        let view = KytosPaneDragSourceView()
        view.paneID = paneID
        view.onDragStateChanged = { dragging in
            DispatchQueue.main.async { isDragging = dragging }
        }
        return view
    }

    func updateNSView(_ nsView: KytosPaneDragSourceView, context: Context) {
        nsView.paneID = paneID
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
    @State private var isDragging = false

    var body: some View {
        ZStack {
            KytosPaneDragSourceRepresentable(paneID: paneID, isDragging: $isDragging)
                .frame(width: 28, height: 24)

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .allowsHitTesting(false)
        }
        .padding(4)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .opacity(isHovering || isDragging ? 1 : 0)
        .animation(.easeInOut(duration: 0.15), value: isHovering)
        .onHover { isHovering = $0 }
        .help("Drag to reorder pane")
        .preference(key: KytosDraggingPaneKey.self, value: isDragging ? paneID : nil)
    }
}
