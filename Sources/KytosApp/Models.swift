import SwiftUI
import UniformTypeIdentifiers

public enum PaneLayoutTree: Codable, Hashable {
    case terminal(id: UUID)
    indirect case split(axis: Axis, left: PaneLayoutTree, right: PaneLayoutTree)
    
    public enum Axis: String, Codable, Hashable {
        case horizontal
        case vertical
    }
    
    public enum MoveDirection {
        case left, right, up, down
    }
    
    public enum PathDirection {
        case left, right
    }
    
    public func path(to id: UUID) -> [PathDirection]? {
        switch self {
        case .terminal(let tid):
            if tid == id { return [] }
            return nil
        case .split(_, let left, let right):
            if let leftPath = left.path(to: id) {
                return [.left] + leftPath
            }
            if let rightPath = right.path(to: id) {
                return [.right] + rightPath
            }
            return nil
        }
    }
    
    public func neighbor(of id: UUID, direction: MoveDirection) -> UUID? {
        guard let p = self.path(to: id) else { return nil }
        
        var targetSubtree: PaneLayoutTree? = nil
        var remainingPath = p
        var ancestorNodes = [PaneLayoutTree]()
        var node = self
        ancestorNodes.append(node)
        
        for step in remainingPath {
            if case .split(_, let left, let right) = node {
                node = (step == .left) ? left : right
                ancestorNodes.append(node)
            }
        }
        
        var i = p.count - 1
        while i >= 0 {
            let parent = ancestorNodes[i]
            let stepTaken = p[i]
            if case .split(let axis, let left, let right) = parent {
                // macOS SwiftUI HStack is horizontal (left/right split)
                if direction == .left && axis == .horizontal && stepTaken == .right {
                    targetSubtree = left
                    break
                }
                if direction == .right && axis == .horizontal && stepTaken == .left {
                    targetSubtree = right
                    break
                }
                // VStack is vertical (up/down split), left=top, right=bottom
                if direction == .up && axis == .vertical && stepTaken == .right {
                    targetSubtree = left
                    break
                }
                if direction == .down && axis == .vertical && stepTaken == .left {
                    targetSubtree = right
                    break
                }
            }
            i -= 1
        }
        
        guard let subtree = targetSubtree else { return nil }
        
        var curr = subtree
        while true {
            switch curr {
            case .terminal(let tid):
                return tid
            case .split(let axis, let left, let right):
                // If moving left into an HStack, land on the right child.
                if direction == .left && axis == .horizontal {
                    curr = right
                } else if direction == .right && axis == .horizontal {
                    curr = left 
                } else if direction == .up && axis == .vertical {
                    curr = right
                } else if direction == .down && axis == .vertical {
                    curr = left
                } else {
                    curr = left
                }
            }
        }
    }
    
    public func removing(id: UUID) -> PaneLayoutTree? {
        switch self {
        case .terminal(let tid):
            return tid == id ? nil : self
        case .split(let axis, let left, let right):
            let newLeft = left.removing(id: id)
            let newRight = right.removing(id: id)
            
            if newLeft == nil && newRight == nil { return nil }
            if newLeft == nil { return newRight }
            if newRight == nil { return newLeft }
            
            return .split(axis: axis, left: newLeft!, right: newRight!)
        }
    }
}

public struct KytosSession: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var layout: PaneLayoutTree
    
    public init(id: UUID = UUID(), name: String = "Session", layout: PaneLayoutTree) {
        self.id = id
        self.name = name
        self.layout = layout
    }
}

public struct KytosTab: Identifiable, Codable, Hashable {
    public var id: UUID
    public var name: String
    public var sessions: [KytosSession]
    public var selectedSessionID: UUID?
    
    public init(id: UUID = UUID(), name: String = "Tab", sessions: [KytosSession] = [], selectedSessionID: UUID? = nil) {
        self.id = id
        self.name = name
        self.sessions = sessions
        self.selectedSessionID = selectedSessionID
    }
}

@Observable
public final class KytosWorkspace {
    public var tabs: [KytosTab]
    public var selectedTabID: UUID?
    
    public init(tabs: [KytosTab] = [], selectedTabID: UUID? = nil) {
        self.tabs = tabs
        self.selectedTabID = selectedTabID
    }
    
    // Persistence engine
    public func save() {
         guard let data = try? JSONEncoder().encode(tabs) else { return }
         UserDefaults.standard.set(data, forKey: "KytosWorkspace_Tabs")
         
         if let id = selectedTabID?.uuidString {
             UserDefaults.standard.set(id, forKey: "KytosWorkspace_SelectedTab")
         }
    }
    
    public static func load() -> KytosWorkspace {
        let decoder = JSONDecoder()
        
        let savedTabs: [KytosTab]
        if let data = UserDefaults.standard.data(forKey: "KytosWorkspace_Tabs"),
           let decoded = try? decoder.decode([KytosTab].self, from: data) {
            savedTabs = decoded
        } else {
            // Ex Nihilo initial state
            let initialTerminal = PaneLayoutTree.terminal(id: UUID())
            let defaultSession = KytosSession(name: "Default", layout: initialTerminal)
            savedTabs = [KytosTab(name: "Terminal", sessions: [defaultSession], selectedSessionID: defaultSession.id)]
        }
        
        var selectedID: UUID? = nil
        if let idString = UserDefaults.standard.string(forKey: "KytosWorkspace_SelectedTab") {
            selectedID = UUID(uuidString: idString)
        } else {
            selectedID = savedTabs.first?.id
        }
        
        return KytosWorkspace(tabs: savedTabs, selectedTabID: selectedID)
    }
}
