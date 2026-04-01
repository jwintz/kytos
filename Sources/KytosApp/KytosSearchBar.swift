// KytosSearchBar.swift — Scrollback search overlay (Cmd+F)

import SwiftUI

/// Observable state for the search overlay, driven by SwiftTerm search results.
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
/// Activated by Cmd+F. Uses SwiftTerm's built-in findNext/findPrevious API.
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

    private var focusedTerminalView: KytosTerminalView? {
        let paneID = workspace.focusedPaneID ?? workspace.splitTree.firstLeaf.id
        return KytosTerminalView.view(for: paneID)
    }

    private func performSearch(_ query: String) {
        guard !query.isEmpty, let view = focusedTerminalView else {
            if query.isEmpty {
                state.totalMatches = 0
                state.selectedMatch = 0
                focusedTerminalView?.endSearch()
            }
            return
        }
        let found = view.searchForward(query)
        // SwiftTerm doesn't provide match counts directly;
        // we track whether at least one match was found.
        state.totalMatches = found ? 1 : 0
        state.selectedMatch = 0
    }

    private func nextMatch() {
        guard let view = focusedTerminalView, !state.query.isEmpty else { return }
        let found = view.searchForward(state.query)
        if found && state.totalMatches > 0 {
            state.selectedMatch = (state.selectedMatch + 1) % max(1, state.totalMatches)
        }
    }

    private func previousMatch() {
        guard let view = focusedTerminalView, !state.query.isEmpty else { return }
        let found = view.searchBackward(state.query)
        if found && state.totalMatches > 0 {
            state.selectedMatch = max(0, state.selectedMatch - 1)
        }
    }

    private func dismiss() {
        focusedTerminalView?.endSearch()
        state.isVisible = false
        state.query = ""
        state.totalMatches = 0
        state.selectedMatch = 0
    }
}
