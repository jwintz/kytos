// KytosSearchBar.swift — Scrollback search overlay (Cmd+F)

import SwiftUI
import GhosttyKit

/// Observable state for the search overlay, driven by ghostty search actions.
@Observable
@MainActor
final class KytosSearchState {
    var isVisible = false
    var query = ""
    var totalMatches: Int = 0
    var selectedMatch: Int = 0

    /// Trigger search navigation from outside (e.g. Cmd+G shortcut)
    var pendingAction: SearchAction?

    enum SearchAction {
        case next, previous
    }

    func searchNext() { pendingAction = .next }
    func searchPrevious() { pendingAction = .previous }
}

/// Search bar overlay for terminal scrollback search.
/// Activated by Cmd+F or ghostty's search keybinding.
struct KytosSearchBar: View {
    @Bindable var state: KytosSearchState
    @Environment(KytosWorkspace.self) private var workspace
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        if state.isVisible {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Search...", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($isFieldFocused)
                    .onSubmit {
                        nextMatch()
                    }
                    .onChange(of: state.query) { _, newValue in
                        performSearch(newValue)
                    }

                // Always show match count when there's a query
                if !state.query.isEmpty {
                    if state.totalMatches > 0 {
                        Text("\(state.selectedMatch + 1)/\(state.totalMatches)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    } else {
                        Text("0/0")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Button(action: previousMatch) {
                    Image(systemName: "chevron.up")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Previous match (Shift+Cmd+G)")

                Button(action: nextMatch) {
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Next match (Cmd+G)")

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Close search (Esc)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .shadow(radius: 2)
            .padding(8)
            .onAppear {
                isFieldFocused = true
            }
            .onChange(of: state.pendingAction) { _, action in
                guard let action else { return }
                state.pendingAction = nil
                switch action {
                case .next: nextMatch()
                case .previous: previousMatch()
                }
            }
        }
    }

    private var focusedSurface: ghostty_surface_t? {
        let paneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        return KytosGhosttyView.view(for: paneID)?.surface
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty, let surface = focusedSurface else {
            if query.isEmpty {
                state.totalMatches = 0
                state.selectedMatch = 0
            }
            return
        }
        let searchCmd = "search:\(query)"
        searchCmd.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(searchCmd.utf8.count))
        }
    }

    private func nextMatch() {
        guard let surface = focusedSurface else { return }
        let cmd = "navigate_search:next"
        cmd.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(cmd.utf8.count))
        }
    }

    private func previousMatch() {
        guard let surface = focusedSurface else { return }
        let cmd = "navigate_search:previous"
        cmd.withCString { ptr in
            _ = ghostty_surface_binding_action(surface, ptr, UInt(cmd.utf8.count))
        }
    }

    private func dismiss() {
        // Tell ghostty to clear its search state
        if let surface = focusedSurface {
            let cmd = "end_search"
            cmd.withCString { ptr in
                _ = ghostty_surface_binding_action(surface, ptr, UInt(cmd.utf8.count))
            }
        }
        state.isVisible = false
        state.query = ""
        state.totalMatches = 0
        state.selectedMatch = 0
    }
}
