// KytosWidget.swift — WidgetKit widget for Kytos terminal app
// Supports systemSmall, systemMedium, systemLarge

import SwiftUI
import WidgetKit

// MARK: - Timeline Provider

struct KytosTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> KytosWidgetEntry {
        KytosWidgetEntry(date: .now, snapshot: .placeholder())
    }

    func getSnapshot(in context: Context, completion: @escaping (KytosWidgetEntry) -> Void) {
        let snapshot = KytosWidgetSnapshot.read() ?? .placeholder()
        completion(KytosWidgetEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<KytosWidgetEntry>) -> Void) {
        let snapshot = KytosWidgetSnapshot.read() ?? .placeholder()
        let entry = KytosWidgetEntry(date: .now, snapshot: snapshot)
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
            SmallWidgetView(entry: entry)
        case .systemMedium:
            MediumWidgetView(entry: entry)
        case .systemLarge:
            LargeWidgetView(entry: entry)
        default:
            SmallWidgetView(entry: entry)
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

// MARK: - Medium (up to 3 windows + top process)

private struct MediumWidgetView: View {
    let entry: KytosWidgetEntry

    private var displayWindows: [KytosWidgetWindow] {
        Array(entry.snapshot.windows.prefix(3))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("Kytos")
                    .font(.headline)
                Spacer()
                Text("\(entry.snapshot.totalTerminals) terminal\(entry.snapshot.totalTerminals == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(entry.snapshot.windows.count) window\(entry.snapshot.windows.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 90, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                ForEach(displayWindows) { window in
                    WindowRowView(window: window, showProcessList: false)
                }
                if entry.snapshot.windows.count > 3 {
                    Text("+\(entry.snapshot.windows.count - 3) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Large (process tree, mirroring inspector design)

private struct LargeWidgetView: View {
    let entry: KytosWidgetEntry

    private var displayedWindows: [KytosWidgetWindow] {
        Array(entry.snapshot.windows.prefix(4))
    }

    private var displayedProcessNodes: [KytosWidgetProcessNode] {
        Array(entry.snapshot.processTree.prefix(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.primary.opacity(0.6))
                    .frame(width: 7, height: 7)
                Text("Kytos")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(entry.snapshot.windows.count)W · \(entry.snapshot.totalTerminals)T")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Process tree
            if entry.snapshot.processTree.isEmpty {
                // Fallback to window list if no process tree data
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(displayedWindows) { window in
                        WindowRowView(window: window, showProcessList: true)
                    }
                    if entry.snapshot.windows.count > displayedWindows.count {
                        Text("+\(entry.snapshot.windows.count - displayedWindows.count) more windows")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
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
                            Spacer()
                            Text(String(format: "%.0f MB", node.rssMB))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(node.cpu)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                    if entry.snapshot.processTree.count > displayedProcessNodes.count {
                        Text("+\(entry.snapshot.processTree.count - displayedProcessNodes.count) more processes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.top, 2)
                    }
                }
            }

            Text("Updated \(entry.snapshot.date, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
