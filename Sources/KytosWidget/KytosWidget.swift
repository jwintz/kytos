// KytosWidget.swift — WidgetKit widget for Kytos terminal app
// Supports systemSmall, systemMedium, systemLarge

import SwiftUI
import WidgetKit

/// Bump this number each build to verify widget recompilation.
private let kWidgetBuildNumber = 7

// MARK: - Timeline Provider

struct KytosTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> KytosWidgetEntry {
        KytosWidgetEntry(date: .now, snapshot: .placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (KytosWidgetEntry) -> Void) {
        let snapshot = KytosWidgetSnapshot.read() ?? .placeholder()
        completion(KytosWidgetEntry(date: snapshot.date, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KytosWidgetEntry>) -> Void) {
        let snapshot = KytosWidgetSnapshot.read() ?? .placeholder()
        let entry = KytosWidgetEntry(date: snapshot.date, snapshot: snapshot)
        let next = Calendar.current.date(byAdding: .minute, value: 1, to: .now) ?? .now
        let timeline = Timeline(entries: [entry], policy: .after(next))
        completion(timeline)
    }
}

// MARK: - Entry

struct KytosWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: KytosWidgetSnapshot
}

// MARK: - Widget Definition

struct KytosWidget: Widget {
    let kind: String = "KytosWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: KytosTimelineProvider()) { entry in
            KytosWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Kytos")
        .description("Live terminal session stats.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Top-level Router

struct KytosWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: KytosWidgetEntry

    var body: some View {
        switch family {
        case .systemSmall:
            SmallWidgetView(entry: entry).id(entry.snapshot.version)
        case .systemMedium:
            MediumWidgetView(entry: entry).id(entry.snapshot.version)
        case .systemLarge:
            LargeWidgetView(entry: entry).id(entry.snapshot.version)
        default:
            SmallWidgetView(entry: entry).id(entry.snapshot.version)
        }
    }
}

// MARK: - Small (icon + counts)

private struct SmallWidgetView: View {
    let entry: KytosWidgetEntry

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)

            Text("\(entry.snapshot.totalTerminals)")
                .font(.system(size: 32, weight: .light, design: .rounded))
                .foregroundStyle(.primary)

            Text(entry.snapshot.totalTerminals == 1 ? "terminal" : "terminals")
                .font(.caption2)
                .foregroundStyle(.secondary)

            if entry.snapshot.windows.count > 0 {
                Text("\(entry.snapshot.windows.count) \(entry.snapshot.windows.count == 1 ? "window" : "windows")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Medium (left branding + right navigator pane grid)

private struct MediumWidgetView: View {
    let entry: KytosWidgetEntry

    private var displayPanes: [KytosWidgetPane] {
        Array(entry.snapshot.panes.prefix(3))
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left column — branding + counts
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Kytos")
                    .font(.headline)
                Text("b\(kWidgetBuildNumber)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
                Spacer(minLength: 0)
                Text("\(entry.snapshot.panes.count) pane\(entry.snapshot.panes.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(entry.snapshot.windows.count) window\(entry.snapshot.windows.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(width: 80, alignment: .leading)

            Divider().padding(.horizontal, 6)

            // Right column — pane grid
            Grid(alignment: .leading, verticalSpacing: 4) {
                if displayPanes.isEmpty {
                    ForEach(Array(entry.snapshot.windows.prefix(3))) { window in
                        GridRow {
                            WindowRowView(window: window, showProcessList: false)
                        }
                    }
                } else {
                    ForEach(displayPanes) { pane in
                        GridRow {
                            WidgetPaneRowView(pane: pane, isSplit: entry.snapshot.panes.count > 1)
                        }
                    }
                    if entry.snapshot.panes.count > displayPanes.count {
                        GridRow {
                            Text("+\(entry.snapshot.panes.count - displayPanes.count) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                // Spacer row absorbs remaining height
                GridRow { Color.clear }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

/// Navigator-style pane row for medium widget.
private struct WidgetPaneRowView: View {
    let pane: KytosWidgetPane
    let isSplit: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Focus indicator
            Circle()
                .fill(pane.isFocused ? Color.accentColor : Color.clear)
                .frame(width: 6, height: 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(pane.processName)
                    .font(.system(size: 11, weight: pane.isFocused ? .medium : .regular))
                    .lineLimit(1)

                if !pane.path.isEmpty {
                    Text(pane.path)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 0)

            // Position indicator (SF Symbol composition)
            if isSplit, !pane.positionSymbols.isEmpty {
                HStack(spacing: 1) {
                    ForEach(Array(pane.positionSymbols.enumerated()), id: \.offset) { _, symbol in
                        Image(systemName: symbol)
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}

// MARK: - Large (process tree, mirroring inspector design)

private struct LargeWidgetView: View {
    let entry: KytosWidgetEntry

    private var displayedWindows: [KytosWidgetWindow] {
        Array(entry.snapshot.windows.prefix(4))
    }

    private var displayedProcessNodes: [KytosWidgetProcessNode] {
        Array(entry.snapshot.processTree.prefix(8))
    }

    @ViewBuilder
    private var processRows: some View {
        if entry.snapshot.processTree.isEmpty {
            ForEach(displayedWindows) { window in
                WindowRowView(window: window, showProcessList: true)
            }
            if entry.snapshot.windows.count > displayedWindows.count {
                Text("+\(entry.snapshot.windows.count - displayedWindows.count) more windows")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        } else {
            ForEach(displayedProcessNodes) { node in
                HStack(spacing: 4) {
                    if node.depth > 0 {
                        Color.clear.frame(width: CGFloat(node.depth) * 12)
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 7))
                            .foregroundStyle(.quaternary)
                    }
                    Circle()
                        .fill(node.isDeepest ? Color.accentColor : Color.secondary.opacity(0.6))
                        .frame(width: 5, height: 5)
                    Text(node.command)
                        .font(.system(size: 10, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(node.pid))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                    Text(String(format: "%.0f MB", node.rssMB))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(node.cpu)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if entry.snapshot.processTree.count > displayedProcessNodes.count {
                Text("+\(entry.snapshot.processTree.count - displayedProcessNodes.count) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    var body: some View {
        Grid(alignment: .leading, verticalSpacing: 4) {
            // Header
            GridRow {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.primary.opacity(0.6))
                        .frame(width: 7, height: 7)
                    Text("Kytos")
                        .font(.system(size: 11, weight: .medium))
                    Text("b\(kWidgetBuildNumber)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.red)
                    Spacer()
                    Text("\(entry.snapshot.windows.count)W · \(entry.snapshot.totalTerminals)T")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            GridRow { Divider() }

            // Process rows — each in its own GridRow
            processRows

            // Spacer row absorbs remaining height
            GridRow { Color.clear }

            // Footer
            GridRow {
                Text("Updated \(entry.snapshot.date, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}

// MARK: - Shared Window Row

private struct WindowRowView: View {
    let window: KytosWidgetWindow
    let showProcessList: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: "rectangle.split.2x1")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12)
                Text(window.name)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer()
                Text("\(window.terminalCount)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if showProcessList {
                ForEach(window.terminals.prefix(4)) { terminal in
                    Text(terminal.process)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .padding(.leading, 16)
                }
                if window.terminals.count > 4 {
                    Text("+\(window.terminals.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 16)
                }
            } else if let top = window.topProcess {
                Text(top)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 16)
            }
        }
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    KytosWidget()
} timeline: {
    KytosWidgetEntry(date: .now, snapshot: .placeholder())
}

#Preview("Medium", as: .systemMedium) {
    KytosWidget()
} timeline: {
    KytosWidgetEntry(date: .now, snapshot: .placeholder())
}

#Preview("Large", as: .systemLarge) {
    KytosWidget()
} timeline: {
    KytosWidgetEntry(date: .now, snapshot: .placeholder())
}
