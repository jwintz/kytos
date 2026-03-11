// KytosSplitView.swift — Draggable split container with divider

import SwiftUI
import AppKit

struct KytosSplitView<Left: View, Right: View>: View {
    let direction: KytosSplitDirection
    @Binding var ratio: Double
    let onEqualize: () -> Void
    @ViewBuilder let left: () -> Left
    @ViewBuilder let right: () -> Right

    private let dividerVisible: CGFloat = 1
    private let dividerHitArea: CGFloat = 6
    private let minPaneSize: CGFloat = 40

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let isHorizontal = direction == .horizontal
            let totalDimension = isHorizontal ? size.width : size.height
            let dividerTotal = dividerVisible + dividerHitArea
            let available = totalDimension - dividerTotal
            let leftSize = max(minPaneSize, available * ratio)
            let rightSize = max(minPaneSize, available - leftSize)

            if isHorizontal {
                HStack(spacing: 0) {
                    left()
                        .frame(width: leftSize)
                    divider(size: size, isHorizontal: true)
                    right()
                        .frame(width: rightSize)
                }
            } else {
                VStack(spacing: 0) {
                    left()
                        .frame(height: leftSize)
                    divider(size: size, isHorizontal: false)
                    right()
                        .frame(height: rightSize)
                }
            }
        }
    }

    @ViewBuilder
    private func divider(size: CGSize, isHorizontal: Bool) -> some View {
        let totalDimension = isHorizontal ? size.width : size.height
        let dividerTotal = dividerVisible + dividerHitArea
        let available = totalDimension - dividerTotal

        ZStack {
            // Visible divider line
            Rectangle()
                .fill(Color.primary.opacity(0.15))
                .frame(
                    width: isHorizontal ? dividerVisible : nil,
                    height: isHorizontal ? nil : dividerVisible
                )
        }
        .frame(
            width: isHorizontal ? dividerTotal : nil,
            height: isHorizontal ? nil : dividerTotal
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { gesture in
                    let pos = isHorizontal ? gesture.location.x : gesture.location.y
                    // Convert from divider-local to parent coordinate
                    let leftSize = available * ratio
                    let parentPos = leftSize + pos
                    let newRatio = max(minPaneSize, min(parentPos, available - minPaneSize)) / available
                    ratio = newRatio
                }
        )
        .onTapGesture(count: 2) {
            onEqualize()
        }
        .onHover { hovering in
            if hovering {
                (isHorizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
