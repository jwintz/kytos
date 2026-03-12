// KytosSplitTreeView.swift — Recursive SwiftUI view for the split tree

import SwiftUI
import UniformTypeIdentifiers

struct KytosSplitTreeView: View {
    @Bindable var tree: KytosSplitTree
    let focusedPaneID: UUID?
    let onFocusPane: (UUID) -> Void

    var body: some View {
        KytosSplitNodeView(node: $tree.root, tree: tree, focusedPaneID: focusedPaneID, onFocusPane: onFocusPane)
            .onChange(of: focusedPaneID) { _, newID in
                guard let newID else { return }
                DispatchQueue.main.async {
                    if let view = KytosGhosttyView.view(for: newID) {
                        view.window?.makeFirstResponder(view)
                    }
                }
            }
    }
}

private struct KytosSplitNodeView: View {
    @Binding var node: KytosSplitNode
    let tree: KytosSplitTree
    let focusedPaneID: UUID?
    let onFocusPane: (UUID) -> Void

    @State private var dropZone: KytosSplitDropZone?
    @State private var leafSize: CGSize = .zero
    @State private var isSelfDragging = false

    var body: some View {
        switch node {
        case .leaf(let pane):
            leafView(pane: pane)

        case .split(var s):
            KytosSplitView(
                direction: s.direction,
                ratio: Binding(
                    get: { s.ratio },
                    set: { newRatio in
                        s.ratio = newRatio
                        node = .split(s)
                    }
                ),
                onEqualize: {
                    s.ratio = 0.5
                    node = .split(s)
                },
                left: {
                    KytosSplitNodeView(
                        node: Binding(
                            get: { s.left },
                            set: { newLeft in
                                s.left = newLeft
                                node = .split(s)
                            }
                        ),
                        tree: tree,
                        focusedPaneID: focusedPaneID,
                        onFocusPane: onFocusPane
                    )
                },
                right: {
                    KytosSplitNodeView(
                        node: Binding(
                            get: { s.right },
                            set: { newRight in
                                s.right = newRight
                                node = .split(s)
                            }
                        ),
                        tree: tree,
                        focusedPaneID: focusedPaneID,
                        onFocusPane: onFocusPane
                    )
                }
            )
        }
    }

    @ViewBuilder
    private func leafView(pane: KytosPane) -> some View {
        GeometryReader { geometry in
            ZStack {
                TerminalView(terminalID: pane.id, initialPwd: pane.pwd.isEmpty ? nil : pane.pwd)
                    .opacity(focusedPaneID == pane.id || !isSplitContext ? 1.0 : 0.55)
                    .animation(.easeInOut(duration: 0.15), value: focusedPaneID)

                if isSplitContext {
                    VStack {
                        KytosPaneDragHandle(paneID: pane.id)
                            .padding(4)
                        Spacer()
                    }
                }

                // Zone-specific drop overlay (like ghostty) — suppress on source pane
                if !isSelfDragging, let zone = dropZone {
                    zoneOverlay(zone: zone, in: geometry)
                        .allowsHitTesting(false)
                }
            }
            .background {
                if !isSelfDragging {
                    Color.clear
                        .onDrop(of: [.kytosPaneID], delegate: KytosSplitDropDelegate(
                            dropZone: $dropZone,
                            viewSize: geometry.size,
                            targetPaneID: pane.id,
                            tree: tree
                        ))
                }
            }
            .onPreferenceChange(KytosDraggingPaneKey.self) { draggingID in
                isSelfDragging = draggingID == pane.id
                if isSelfDragging { dropZone = nil }
            }
        }
    }

    @ViewBuilder
    private func zoneOverlay(zone: KytosSplitDropZone, in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch zone {
        case .top:
            VStack(spacing: 0) {
                Rectangle().fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle().fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle().fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle().fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }

    private var isSplitContext: Bool {
        true
    }
}

// MARK: - Drop Delegate (tracks zone as cursor moves, like ghostty)

private struct KytosSplitDropDelegate: DropDelegate {
    @Binding var dropZone: KytosSplitDropZone?
    let viewSize: CGSize
    let targetPaneID: UUID
    let tree: KytosSplitTree

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.kytosPaneID])
    }

    func dropEntered(info: DropInfo) {
        dropZone = KytosSplitDropZone.zone(for: info.location, in: viewSize)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropZone = KytosSplitDropZone.zone(for: info.location, in: viewSize)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        dropZone = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = KytosSplitDropZone.zone(for: info.location, in: viewSize)
        let providers = info.itemProviders(for: [.kytosPaneID])
        guard let provider = providers.first else {
            DispatchQueue.main.async { [self] in
                dropZone = nil
            }
            return false
        }

        provider.loadDataRepresentation(forTypeIdentifier: UTType.kytosPaneID.identifier) { data, _ in
            guard let data,
                  let transfer = try? JSONDecoder().decode(KytosPaneTransfer.self, from: data)
            else {
                DispatchQueue.main.async { [self] in
                    dropZone = nil
                }
                return
            }
            guard transfer.paneID != targetPaneID else {
                DispatchQueue.main.async { [self] in
                    dropZone = nil
                }
                return
            }
            DispatchQueue.main.async {
                tree.movePane(sourceID: transfer.paneID, targetID: targetPaneID, zone: zone)
                dropZone = nil
            }
        }
        return true
    }
}
