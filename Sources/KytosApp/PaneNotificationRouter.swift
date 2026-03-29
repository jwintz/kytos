// PaneNotificationRouter.swift — Consolidated notification handling (KY2-2)
//
// Replaces 14+ individual `.onReceive(NotificationCenter.default.publisher(...))` modifiers
// in PaneWorkspaceView. Each SwiftUI body rebuild was re-creating these subscriptions;
// now a single @Observable object subscribes once via Combine.

import SwiftUI
import Combine
import GhosttyKit

@MainActor @Observable
final class PaneNotificationRouter {
    @ObservationIgnored private var cancellables = Set<AnyCancellable>()

    let windowID: UUID
    private let workspace: KytosWorkspace
    private let searchState: KytosSearchState
    /// Closure called to get current split tree size for spatial navigation.
    private let splitTreeSizeProvider: () -> CGSize

    init(
        windowID: UUID,
        workspace: KytosWorkspace,
        searchState: KytosSearchState,
        splitTreeSizeProvider: @escaping () -> CGSize
    ) {
        self.windowID = windowID
        self.workspace = workspace
        self.searchState = searchState
        self.splitTreeSizeProvider = splitTreeSizeProvider
        subscribe()
    }

    private func subscribe() {
        let nc = NotificationCenter.default

        // 1. SetTitle
        nc.publisher(for: NSNotification.Name("KytosGhosttySetTitle"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let title = notif.userInfo?["title"] as? String, !title.isEmpty else { return }
                if let sourceView = notif.object as? KytosGhosttyView,
                   let paneID = sourceView.paneID {
                    self.workspace.splitTree.updateTitle(title, for: paneID)
                } else {
                    let targetID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                    self.workspace.splitTree.updateTitle(title, for: targetID)
                }
            }
            .store(in: &cancellables)

        // 2. Pwd
        nc.publisher(for: NSNotification.Name("KytosGhosttyPwd"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let pwd = notif.userInfo?["pwd"] as? String else { return }
                if let sourceView = notif.object as? KytosGhosttyView,
                   let paneID = sourceView.paneID {
                    self.workspace.splitTree.updatePwd(pwd, for: paneID)
                } else {
                    let targetID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                    self.workspace.splitTree.updatePwd(pwd, for: targetID)
                }
            }
            .store(in: &cancellables)

        // 3. NewSplit
        nc.publisher(for: NSNotification.Name("KytosGhosttyNewSplit"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let direction = notif.userInfo?["direction"] as? KytosSplitDirection else { return }
                let targetPaneID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                let newPane = KytosPane()
                self.workspace.splitTree.split(at: targetPaneID, direction: direction, newPane: newPane)
                self.workspace.focusedPaneID = newPane.id
            }
            .store(in: &cancellables)

        // 4. GotoSplit
        nc.publisher(for: NSNotification.Name("KytosGhosttyGotoSplit"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.handleGotoSplit(notif)
            }
            .store(in: &cancellables)

        // 5. EqualizeSplits
        nc.publisher(for: NSNotification.Name("KytosGhosttyEqualizeSplits"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.workspace.splitTree.equalize()
            }
            .store(in: &cancellables)

        // 6. CloseSurface
        nc.publisher(for: NSNotification.Name("KytosGhosttyCloseSurface"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let focusedID = self.workspace.focusedPaneID else { return }
                guard self.workspace.splitTree.isSplit else {
                    KytosAppModel.shared.window(for: self.windowID)?.performClose(nil)
                    return
                }
                KytosGhosttyView.view(for: focusedID)?.closeSurface()
                if let newFocusID = self.workspace.splitTree.remove(paneID: focusedID) {
                    self.workspace.focusedPaneID = newFocusID
                }
            }
            .store(in: &cancellables)

        // 7. SearchTotal
        nc.publisher(for: NSNotification.Name("KytosGhosttySearchTotal"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                if let total = notif.userInfo?["total"] as? Int {
                    self.searchState.totalMatches = max(0, total)
                }
            }
            .store(in: &cancellables)

        // 8. SearchSelected
        nc.publisher(for: NSNotification.Name("KytosGhosttySearchSelected"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                if let selected = notif.userInfo?["selected"] as? Int {
                    self.searchState.selectedMatch = max(0, selected)
                }
            }
            .store(in: &cancellables)

        // 9. StartSearch
        nc.publisher(for: NSNotification.Name("KytosGhosttyStartSearch"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.searchState.isVisible = true
            }
            .store(in: &cancellables)

        // 10. FocusChanged
        nc.publisher(for: NSNotification.Name("KytosGhosttyFocusChanged"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif),
                      let paneID = notif.userInfo?["paneID"] as? UUID else { return }
                self.workspace.focusedPaneID = paneID
            }
            .store(in: &cancellables)

        // 11. SearchNext
        nc.publisher(for: NSNotification.Name("KytosSearchNext"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard self.searchState.isVisible else { return }
                self.searchState.searchNext()
            }
            .store(in: &cancellables)

        // 12. SearchPrevious
        nc.publisher(for: NSNotification.Name("KytosSearchPrevious"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard self.searchState.isVisible else { return }
                self.searchState.searchPrevious()
            }
            .store(in: &cancellables)

        // 13. ResetFontSize
        nc.publisher(for: NSNotification.Name("KytosResetFontSize"))
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                let focusedID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                guard let view = KytosGhosttyView.view(for: focusedID),
                      let surface = view.surface else { return }
                let cmd = "reset_font_size"
                _ = cmd.withCString { ptr in
                    ghostty_surface_binding_action(surface, ptr, UInt(cmd.utf8.count))
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Window targeting (same logic as the original notificationTargetsCurrentWindow)

    private func targets(_ notification: Notification) -> Bool {
        if let targetWindowID = notification.userInfo?["windowID"] as? UUID {
            return targetWindowID == windowID
        }
        if let sourceView = notification.object as? KytosGhosttyView,
           let paneID = sourceView.paneID {
            return workspace.splitTree.findPane(paneID) != nil
        }
        return false
    }

    // MARK: - GotoSplit (complex handler extracted verbatim)

    private func handleGotoSplit(_ notif: Notification) {
        guard let currentID = workspace.focusedPaneID else { return }
        let panes = workspace.splitTree.allPanes
        guard panes.count > 1 else { return }
        guard let idx = panes.firstIndex(where: { $0.id == currentID }) else { return }

        let rawDir: UInt32
        if let r = notif.userInfo?["direction"] as? UInt32 {
            rawDir = r
        } else if let r = notif.userInfo?["direction"] as? Int {
            rawDir = UInt32(r)
        } else {
            kLog("[GotoSplit] No direction in notification")
            return
        }

        kLog("[GotoSplit] rawDir=\(rawDir) LEFT=\(GHOSTTY_GOTO_SPLIT_LEFT.rawValue) RIGHT=\(GHOSTTY_GOTO_SPLIT_RIGHT.rawValue) UP=\(GHOSTTY_GOTO_SPLIT_UP.rawValue) DOWN=\(GHOSTTY_GOTO_SPLIT_DOWN.rawValue) NEXT=\(GHOSTTY_GOTO_SPLIT_NEXT.rawValue) PREV=\(GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue)")

        let spatialDir: KytosSplitTree.SpatialDirection?
        let forward: Bool?
        switch rawDir {
        case GHOSTTY_GOTO_SPLIT_LEFT.rawValue:     spatialDir = .left;  forward = nil
        case GHOSTTY_GOTO_SPLIT_RIGHT.rawValue:    spatialDir = .right; forward = nil
        case GHOSTTY_GOTO_SPLIT_UP.rawValue:       spatialDir = .up;    forward = nil
        case GHOSTTY_GOTO_SPLIT_DOWN.rawValue:     spatialDir = .down;  forward = nil
        case GHOSTTY_GOTO_SPLIT_NEXT.rawValue:     spatialDir = nil;    forward = true
        case GHOSTTY_GOTO_SPLIT_PREVIOUS.rawValue: spatialDir = nil;    forward = false
        default:
            kLog("[GotoSplit] Unknown direction \(rawDir), falling back to next")
            let nextIdx = (idx + 1) % panes.count
            workspace.focusedPaneID = panes[nextIdx].id
            return
        }

        if let spatialDir {
            let splitTreeSize = splitTreeSizeProvider()
            let bounds = CGRect(origin: .zero, size: splitTreeSize)
            let slots = workspace.splitTree.spatialSlots(in: bounds)
            kLog("[GotoSplit] spatial=\(spatialDir) bounds=\(bounds) slots=\(slots.map { "\($0.paneID.uuidString.prefix(4)):\($0.bounds)" })")
            if let nextID = workspace.splitTree.geometricNeighbor(from: currentID, direction: spatialDir, in: bounds) {
                kLog("[GotoSplit] → neighbor \(nextID.uuidString.prefix(4))")
                workspace.focusedPaneID = nextID
            } else {
                let nextIdx: Int
                switch spatialDir {
                case .right, .down: nextIdx = (idx + 1) % panes.count
                case .left, .up:    nextIdx = (idx - 1 + panes.count) % panes.count
                }
                workspace.focusedPaneID = panes[nextIdx].id
            }
        } else if let forward {
            let nextIdx: Int
            if forward {
                nextIdx = (idx + 1) % panes.count
            } else {
                nextIdx = (idx - 1 + panes.count) % panes.count
            }
            workspace.focusedPaneID = panes[nextIdx].id
        }
    }
}
