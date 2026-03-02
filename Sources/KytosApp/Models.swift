import SwiftUI
import UniformTypeIdentifiers

public enum PaneLayoutTree: Codable, Hashable {
    case terminal(id: UUID)
    indirect case split(axis: Axis, left: PaneLayoutTree, right: PaneLayoutTree)
    
    public enum Axis: String, Codable, Hashable {
        case horizontal
        case vertical
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
