// PaneNotificationRouter.swift — Consolidated notification handling (KY2-2)
//
// Replaces 14+ individual `.onReceive(NotificationCenter.default.publisher(...))` modifiers
// in PaneWorkspaceView. Each SwiftUI body rebuild was re-creating these subscriptions;
// now a single @Observable object subscribes once via Combine.

import SwiftUI
import Combine

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
        nc.publisher(for: .kytosTerminalSetTitle)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let title = notif.userInfo?["title"] as? String, !title.isEmpty else { return }
                if let sourceView = notif.object as? KytosTerminalView,
                   let paneID = sourceView.paneID {
                    self.workspace.splitTree.updateTitle(title, for: paneID)
                } else {
                    let targetID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                    self.workspace.splitTree.updateTitle(title, for: targetID)
                }
            }
            .store(in: &cancellables)

        // 2. Pwd
        nc.publisher(for: .kytosTerminalPwd)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let pwd = notif.userInfo?["pwd"] as? String else { return }
                if let sourceView = notif.object as? KytosTerminalView,
                   let paneID = sourceView.paneID {
                    self.workspace.splitTree.updatePwd(pwd, for: paneID)
                } else {
                    let targetID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                    self.workspace.splitTree.updatePwd(pwd, for: targetID)
                }
            }
            .store(in: &cancellables)

        // 3. NewSplit
        nc.publisher(for: .kytosTerminalNewSplit)
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
        nc.publisher(for: .kytosTerminalGotoSplit)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.handleGotoSplit(notif)
            }
            .store(in: &cancellables)

        // 5. EqualizeSplits
        nc.publisher(for: .kytosTerminalEqualizeSplits)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.workspace.splitTree.equalize()
            }
            .store(in: &cancellables)

        // 6. CloseSurface
        nc.publisher(for: .kytosTerminalCloseSurface)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard let focusedID = self.workspace.focusedPaneID else { return }
                guard self.workspace.splitTree.isSplit else {
                    KytosAppModel.shared.window(for: self.windowID)?.performClose(nil)
                    return
                }
                KytosTerminalView.view(for: focusedID)?.closeSurface()
                if let newFocusID = self.workspace.splitTree.remove(paneID: focusedID) {
                    self.workspace.focusedPaneID = newFocusID
                }
            }
            .store(in: &cancellables)

        // 7. StartSearch
        nc.publisher(for: .kytosTerminalStartSearch)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                self.searchState.isVisible = true
            }
            .store(in: &cancellables)

        // 8. FocusChanged
        nc.publisher(for: .kytosTerminalFocusChanged)
            .sink { [weak self] notif in
                guard let self, self.targets(notif),
                      let paneID = notif.userInfo?["paneID"] as? UUID else { return }
                self.workspace.focusedPaneID = paneID
            }
            .store(in: &cancellables)

        // 9. SearchNext
        nc.publisher(for: .kytosSearchNext)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard self.searchState.isVisible else { return }
                self.searchState.searchNext()
            }
            .store(in: &cancellables)

        // 10. SearchPrevious
        nc.publisher(for: .kytosSearchPrevious)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                guard self.searchState.isVisible else { return }
                self.searchState.searchPrevious()
            }
            .store(in: &cancellables)

        // 11. ResetFontSize
        nc.publisher(for: .kytosResetFontSize)
            .sink { [weak self] notif in
                guard let self, self.targets(notif) else { return }
                let focusedID = self.workspace.focusedPaneID ?? self.workspace.splitTree.firstLeaf.id
                KytosTerminalView.view(for: focusedID)?.resetKytosFontSize()
            }
            .store(in: &cancellables)
    }

    // MARK: - Window targeting

    private func targets(_ notification: Notification) -> Bool {
        if let targetWindowID = notification.userInfo?["windowID"] as? UUID {
            return targetWindowID == windowID
        }
        if let sourceView = notification.object as? KytosTerminalView,
           let paneID = sourceView.paneID {
            return workspace.splitTree.findPane(paneID) != nil
        }
        return false
    }

    // MARK: - GotoSplit

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

        kLog("[GotoSplit] rawDir=\(rawDir)")

        let spatialDir: KytosSplitTree.SpatialDirection?
        let forward: Bool?
        switch rawDir {
        case KytosGotoSplitDirection.left.rawValue:     spatialDir = .left;  forward = nil
        case KytosGotoSplitDirection.right.rawValue:    spatialDir = .right; forward = nil
        case KytosGotoSplitDirection.up.rawValue:       spatialDir = .up;    forward = nil
        case KytosGotoSplitDirection.down.rawValue:     spatialDir = .down;  forward = nil
        case KytosGotoSplitDirection.next.rawValue:     spatialDir = nil;    forward = true
        case KytosGotoSplitDirection.previous.rawValue: spatialDir = nil;    forward = false
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
