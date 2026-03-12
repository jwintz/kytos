// KytosSplitTree.swift — Split tree data structure for pane management

import Foundation

// MARK: - Pane

public struct KytosPane: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var pwd: String
    public var processName: String

    public init(id: UUID = UUID(), title: String = "", pwd: String = "", processName: String = "") {
        self.id = id
        self.title = title
        self.pwd = pwd
        self.processName = processName
    }
}

extension KytosPane: Codable {
    enum CodingKeys: String, CodingKey { case id, title, pwd, processName }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        pwd = try c.decodeIfPresent(String.self, forKey: .pwd) ?? ""
        processName = try c.decodeIfPresent(String.self, forKey: .processName) ?? ""
    }
}

// MARK: - Split Direction

public enum KytosSplitDirection: String, Codable, Sendable {
    case horizontal // left | right
    case vertical   // top / bottom
}

// MARK: - Split Node

public indirect enum KytosSplitNode: Codable, Sendable {
    case leaf(KytosPane)
    case split(KytosSplit)

    public struct KytosSplit: Codable, Sendable {
        public var direction: KytosSplitDirection
        public var ratio: Double
        public var left: KytosSplitNode  // left for horizontal, top for vertical
        public var right: KytosSplitNode // right for horizontal, bottom for vertical

        public init(direction: KytosSplitDirection, ratio: Double = 0.5, left: KytosSplitNode, right: KytosSplitNode) {
            self.direction = direction
            self.ratio = ratio
            self.left = left
            self.right = right
        }
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case type, pane, split
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "leaf":
            let pane = try container.decode(KytosPane.self, forKey: .pane)
            self = .leaf(pane)
        case "split":
            let split = try container.decode(KytosSplit.self, forKey: .split)
            self = .split(split)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown node type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane):
            try container.encode("leaf", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

// MARK: - Split Tree

@Observable
public final class KytosSplitTree: Codable, @unchecked Sendable {
    public var root: KytosSplitNode

    public init(root: KytosSplitNode) {
        self.root = root
    }

    public convenience init(pane: KytosPane) {
        self.init(root: .leaf(pane))
    }

    // MARK: - Codable

    enum CodingKeys: String, CodingKey { case root }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.root = try container.decode(KytosSplitNode.self, forKey: .root)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(root, forKey: .root)
    }

    // MARK: - Query

    /// First leaf pane in the tree (leftmost/topmost).
    public var firstLeaf: KytosPane {
        Self.firstLeaf(of: root)
    }

    private static func firstLeaf(of node: KytosSplitNode) -> KytosPane {
        switch node {
        case .leaf(let pane): return pane
        case .split(let s): return firstLeaf(of: s.left)
        }
    }

    /// All leaf panes in the tree, in order.
    public var allPanes: [KytosPane] {
        var result: [KytosPane] = []
        Self.collectLeaves(node: root, into: &result)
        return result
    }

    private static func collectLeaves(node: KytosSplitNode, into result: inout [KytosPane]) {
        switch node {
        case .leaf(let pane):
            result.append(pane)
        case .split(let s):
            collectLeaves(node: s.left, into: &result)
            collectLeaves(node: s.right, into: &result)
        }
    }

    /// Find the pane with the given ID.
    public func findPane(_ id: UUID) -> KytosPane? {
        Self.findPane(id, in: root)
    }

    private static func findPane(_ id: UUID, in node: KytosSplitNode) -> KytosPane? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(let s):
            return findPane(id, in: s.left) ?? findPane(id, in: s.right)
        }
    }

    /// Whether the tree has more than one pane.
    public var isSplit: Bool {
        if case .split = root { return true }
        return false
    }

    // MARK: - Mutation

    /// Split a pane, inserting a new pane next to it.
    public func split(at paneID: UUID, direction: KytosSplitDirection, newPane: KytosPane) {
        root = Self.insertSplit(node: root, at: paneID, direction: direction, newPane: newPane)
    }

    private static func insertSplit(node: KytosSplitNode, at paneID: UUID, direction: KytosSplitDirection, newPane: KytosPane) -> KytosSplitNode {
        switch node {
        case .leaf(let pane):
            if pane.id == paneID {
                return .split(.init(direction: direction, left: .leaf(pane), right: .leaf(newPane)))
            }
            return node
        case .split(let s):
            let newLeft = insertSplit(node: s.left, at: paneID, direction: direction, newPane: newPane)
            let newRight = insertSplit(node: s.right, at: paneID, direction: direction, newPane: newPane)
            return .split(.init(direction: s.direction, ratio: s.ratio, left: newLeft, right: newRight))
        }
    }

    /// Remove a pane from the tree. The sibling takes the parent's place.
    /// Returns the ID of the pane that should receive focus (sibling's first leaf).
    @discardableResult
    public func remove(paneID: UUID) -> UUID? {
        guard let (newRoot, focusID) = Self.removeNode(node: root, paneID: paneID) else { return nil }
        root = newRoot
        return focusID
    }

    private static func removeNode(node: KytosSplitNode, paneID: UUID) -> (KytosSplitNode, UUID)? {
        switch node {
        case .leaf(let pane):
            // Can't remove the root leaf
            if pane.id == paneID { return nil }
            return nil
        case .split(let s):
            // Check if left child is the target
            if case .leaf(let leftPane) = s.left, leftPane.id == paneID {
                return (s.right, firstLeaf(of: s.right).id)
            }
            // Check if right child is the target
            if case .leaf(let rightPane) = s.right, rightPane.id == paneID {
                return (s.left, firstLeaf(of: s.left).id)
            }
            // Recurse into children
            if let (newLeft, focusID) = removeNode(node: s.left, paneID: paneID) {
                return (.split(.init(direction: s.direction, ratio: s.ratio, left: newLeft, right: s.right)), focusID)
            }
            if let (newRight, focusID) = removeNode(node: s.right, paneID: paneID) {
                return (.split(.init(direction: s.direction, ratio: s.ratio, left: s.left, right: newRight)), focusID)
            }
            return nil
        }
    }

    /// Equalize all split ratios to 50%.
    public func equalize() {
        root = Self.equalized(node: root)
    }

    private static func equalized(node: KytosSplitNode) -> KytosSplitNode {
        switch node {
        case .leaf: return node
        case .split(let s):
            return .split(.init(direction: s.direction, ratio: 0.5, left: equalized(node: s.left), right: equalized(node: s.right)))
        }
    }

    /// Update a split ratio at the given pane boundary.
    public func resize(at paneID: UUID, ratio: Double) {
        root = Self.resized(node: root, at: paneID, ratio: ratio)
    }

    private static func resized(node: KytosSplitNode, at paneID: UUID, ratio: Double) -> KytosSplitNode {
        switch node {
        case .leaf: return node
        case .split(let s):
            // If this split contains the target pane on either side, update ratio
            if Self.containsPane(paneID, in: s.left) {
                if case .leaf(let p) = s.left, p.id == paneID {
                    return .split(.init(direction: s.direction, ratio: ratio, left: s.left, right: s.right))
                }
            }
            if Self.containsPane(paneID, in: s.right) {
                if case .leaf(let p) = s.right, p.id == paneID {
                    return .split(.init(direction: s.direction, ratio: ratio, left: s.left, right: s.right))
                }
            }
            let newLeft = resized(node: s.left, at: paneID, ratio: ratio)
            let newRight = resized(node: s.right, at: paneID, ratio: ratio)
            return .split(.init(direction: s.direction, ratio: s.ratio, left: newLeft, right: newRight))
        }
    }

    private static func containsPane(_ id: UUID, in node: KytosSplitNode) -> Bool {
        switch node {
        case .leaf(let pane): return pane.id == id
        case .split(let s): return containsPane(id, in: s.left) || containsPane(id, in: s.right)
        }
    }

    /// Update pane title by ID.
    public func updateTitle(_ title: String, for paneID: UUID) {
        root = Self.updatedTitle(node: root, paneID: paneID, title: title)
    }

    private static func updatedTitle(node: KytosSplitNode, paneID: UUID, title: String) -> KytosSplitNode {
        switch node {
        case .leaf(var pane):
            if pane.id == paneID { pane.title = title }
            return .leaf(pane)
        case .split(let s):
            return .split(.init(direction: s.direction, ratio: s.ratio,
                                left: updatedTitle(node: s.left, paneID: paneID, title: title),
                                right: updatedTitle(node: s.right, paneID: paneID, title: title)))
        }
    }

    /// Update pane process name by ID.
    public func updateProcessName(_ name: String, for paneID: UUID) {
        root = Self.updatedProcessName(node: root, paneID: paneID, name: name)
    }

    private static func updatedProcessName(node: KytosSplitNode, paneID: UUID, name: String) -> KytosSplitNode {
        switch node {
        case .leaf(var pane):
            if pane.id == paneID { pane.processName = name }
            return .leaf(pane)
        case .split(let s):
            return .split(.init(direction: s.direction, ratio: s.ratio,
                                left: updatedProcessName(node: s.left, paneID: paneID, name: name),
                                right: updatedProcessName(node: s.right, paneID: paneID, name: name)))
        }
    }

    /// Update pane working directory by ID.
    public func updatePwd(_ pwd: String, for paneID: UUID) {
        root = Self.updatedPwd(node: root, paneID: paneID, pwd: pwd)
    }

    private static func updatedPwd(node: KytosSplitNode, paneID: UUID, pwd: String) -> KytosSplitNode {
        switch node {
        case .leaf(var pane):
            if pane.id == paneID { pane.pwd = pwd }
            return .leaf(pane)
        case .split(let s):
            return .split(.init(direction: s.direction, ratio: s.ratio,
                                left: updatedPwd(node: s.left, paneID: paneID, pwd: pwd),
                                right: updatedPwd(node: s.right, paneID: paneID, pwd: pwd)))
        }
    }

    // MARK: - Position Path

    /// Returns a human-readable path like "Left > Top" for a pane in the tree.
    public func positionPath(for paneID: UUID) -> String? {
        Self.pathToPane(paneID, in: root, path: [])?.joined(separator: " > ")
    }

    /// A single step in the split tree path, with an associated SF Symbol.
    public struct PositionStep: Sendable {
        public let label: String
        public let sfSymbol: String
    }

    /// Returns the position steps for a pane, each with an SF Symbol for visual representation.
    public func positionSteps(for paneID: UUID) -> [PositionStep]? {
        Self.stepsToPane(paneID, in: root, steps: [])
    }

    private static func stepsToPane(_ id: UUID, in node: KytosSplitNode, steps: [PositionStep]) -> [PositionStep]? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? steps : nil
        case .split(let s):
            let leftStep: PositionStep
            let rightStep: PositionStep
            if s.direction == .horizontal {
                leftStep = PositionStep(label: "Left", sfSymbol: "rectangle.lefthalf.filled")
                rightStep = PositionStep(label: "Right", sfSymbol: "rectangle.righthalf.filled")
            } else {
                leftStep = PositionStep(label: "Top", sfSymbol: "rectangle.tophalf.filled")
                rightStep = PositionStep(label: "Bottom", sfSymbol: "rectangle.bottomhalf.filled")
            }
            return stepsToPane(id, in: s.left, steps: steps + [leftStep])
                ?? stepsToPane(id, in: s.right, steps: steps + [rightStep])
        }
    }

    private static func pathToPane(_ id: UUID, in node: KytosSplitNode, path: [String]) -> [String]? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? path : nil
        case .split(let s):
            let leftLabel = s.direction == .horizontal ? "Left" : "Top"
            let rightLabel = s.direction == .horizontal ? "Right" : "Bottom"
            return pathToPane(id, in: s.left, path: path + [leftLabel])
                ?? pathToPane(id, in: s.right, path: path + [rightLabel])
        }
    }

    // MARK: - Spatial Navigation

    public struct SpatialSlot {
        public let paneID: UUID
        public let bounds: CGRect
    }

    public enum SpatialDirection {
        case left, right, up, down
    }

    /// Compute the spatial bounds of each leaf pane by recursively subdividing.
    public func spatialSlots(in bounds: CGRect) -> [SpatialSlot] {
        var result: [SpatialSlot] = []
        Self.computeSlots(node: root, bounds: bounds, into: &result)
        return result
    }

    private static func computeSlots(node: KytosSplitNode, bounds: CGRect, into result: inout [SpatialSlot]) {
        switch node {
        case .leaf(let pane):
            result.append(SpatialSlot(paneID: pane.id, bounds: bounds))
        case .split(let s):
            let isHorizontal = s.direction == .horizontal
            if isHorizontal {
                let leftWidth = bounds.width * s.ratio
                let leftBounds = CGRect(x: bounds.minX, y: bounds.minY, width: leftWidth, height: bounds.height)
                let rightBounds = CGRect(x: bounds.minX + leftWidth, y: bounds.minY, width: bounds.width - leftWidth, height: bounds.height)
                computeSlots(node: s.left, bounds: leftBounds, into: &result)
                computeSlots(node: s.right, bounds: rightBounds, into: &result)
            } else {
                let topHeight = bounds.height * s.ratio
                let topBounds = CGRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: topHeight)
                let bottomBounds = CGRect(x: bounds.minX, y: bounds.minY + topHeight, width: bounds.width, height: bounds.height - topHeight)
                computeSlots(node: s.left, bounds: topBounds, into: &result)
                computeSlots(node: s.right, bounds: bottomBounds, into: &result)
            }
        }
    }

    /// Find the geometric neighbor from a given pane in the specified direction.
    /// Uses edge-based filtering (like ghostty): a pane is "to the left" only if its
    /// right edge is at or left of the source's left edge. Distance is measured from
    /// top-left corners.
    public func geometricNeighbor(from paneID: UUID, direction: SpatialDirection, in bounds: CGRect) -> UUID? {
        let slots = spatialSlots(in: bounds)
        guard let sourceSlot = slots.first(where: { $0.paneID == paneID }) else {
            kLog("[GeoNav] source \(paneID.uuidString.prefix(4)) not found in \(slots.count) slots, bounds=\(bounds)")
            return nil
        }
        let ref = sourceSlot.bounds

        var candidates: [(UUID, Double)] = []
        for slot in slots where slot.paneID != paneID {
            let b = slot.bounds
            let inDirection: Bool
            switch direction {
            case .left:  inDirection = b.maxX <= ref.minX + 1
            case .right: inDirection = b.minX >= ref.maxX - 1
            case .up:    inDirection = b.maxY <= ref.minY + 1
            case .down:  inDirection = b.minY >= ref.maxY - 1
            }
            if inDirection {
                let dx = b.minX - ref.minX
                let dy = b.minY - ref.minY
                let dist = sqrt(dx * dx + dy * dy)
                candidates.append((slot.paneID, dist))
            }
        }
        candidates.sort { $0.1 < $1.1 }
        kLog("[GeoNav] dir=\(direction) from=\(paneID.uuidString.prefix(4)) ref=\(ref) candidates=\(candidates.map { "\($0.0.uuidString.prefix(4))@\($0.1)" })")
        return candidates.first?.0
    }

    // MARK: - Sequential Navigation

    /// Get the next pane ID in the given direction from the focused pane.
    public func nextPane(from currentID: UUID, direction: KytosSplitDirection, forward: Bool) -> UUID? {
        let panes = allPanes
        guard let idx = panes.firstIndex(where: { $0.id == currentID }) else { return nil }
        let nextIdx = forward ? panes.index(after: idx) : panes.index(before: idx)
        guard panes.indices.contains(nextIdx) else { return nil }
        return panes[nextIdx].id
    }

    // MARK: - Drag and Drop

    /// Move a pane from one location to another, splitting the target in the given zone direction.
    public func movePane(sourceID: UUID, targetID: UUID, zone: KytosSplitDropZone) {
        guard sourceID != targetID else { return }
        // Extract the source pane first
        guard let sourcePane = findPane(sourceID) else { return }
        // Remove source from tree
        guard let (treeWithoutSource, _) = Self.removeNode(node: root, paneID: sourceID) else { return }
        // Insert source next to target in the specified zone direction
        let direction: KytosSplitDirection = (zone == .left || zone == .right) ? .horizontal : .vertical
        let sourceOnLeft = (zone == .left || zone == .top)
        root = Self.insertAt(node: treeWithoutSource, targetID: targetID, newPane: sourcePane, direction: direction, newPaneFirst: sourceOnLeft)
    }

    private static func insertAt(node: KytosSplitNode, targetID: UUID, newPane: KytosPane, direction: KytosSplitDirection, newPaneFirst: Bool) -> KytosSplitNode {
        switch node {
        case .leaf(let pane):
            if pane.id == targetID {
                let left: KytosSplitNode = newPaneFirst ? .leaf(newPane) : .leaf(pane)
                let right: KytosSplitNode = newPaneFirst ? .leaf(pane) : .leaf(newPane)
                return .split(.init(direction: direction, left: left, right: right))
            }
            return node
        case .split(let s):
            let newLeft = insertAt(node: s.left, targetID: targetID, newPane: newPane, direction: direction, newPaneFirst: newPaneFirst)
            let newRight = insertAt(node: s.right, targetID: targetID, newPane: newPane, direction: direction, newPaneFirst: newPaneFirst)
            return .split(.init(direction: s.direction, ratio: s.ratio, left: newLeft, right: newRight))
        }
    }

    /// Iterate over all leaf panes.
    public func forEachLeaf(_ body: (KytosPane) -> Void) {
        Self.forEachLeaf(node: root, body)
    }

    private static func forEachLeaf(node: KytosSplitNode, _ body: (KytosPane) -> Void) {
        switch node {
        case .leaf(let pane): body(pane)
        case .split(let s):
            forEachLeaf(node: s.left, body)
            forEachLeaf(node: s.right, body)
        }
    }
}
