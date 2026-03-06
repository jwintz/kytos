// KytosWidget.swift — WidgetKit widget for Kytos terminal app
// Supports systemSmall, systemMedium, systemLarge (+ systemExtraLarge on iOS)

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
        .supportedFamilies({
            var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge]
            #if os(iOS)
            families.append(.systemExtraLarge)
            #endif
            return families
        }())
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
#if os(iOS)
        case .systemExtraLarge:
            ExtraLargeWidgetView(entry: entry)
#endif
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

// MARK: - Large (all windows with process list + timestamp)

private struct LargeWidgetView: View {
    let entry: KytosWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "terminal")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Kytos")
                        .font(.headline)
                    Text("\(entry.snapshot.windows.count) windows · \(entry.snapshot.totalTerminals) terminals")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.snapshot.windows) { window in
                    WindowRowView(window: window, showProcessList: true)
                }
            }

            Spacer(minLength: 0)

            Text("Updated \(entry.snapshot.date, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Extra Large (iOS, 2-column grid)

#if os(iOS)
private struct ExtraLargeWidgetView: View {
    let entry: KytosWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "terminal")
                    .font(.title)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading) {
                    Text("Kytos")
                        .font(.title3)
                        .fontWeight(.semibold)
                    Text("\(entry.snapshot.windows.count) windows · \(entry.snapshot.totalTerminals) terminals")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(entry.snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 4) {
                            Image(systemName: "rectangle.split.2x1")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(window.name)
                                .font(.callout)
                                .fontWeight(.medium)
                            Spacer()
                            Text("\(window.terminalCount)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(window.terminals.prefix(3)) { terminal in
                            Text(terminal.process)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if window.terminals.count > 3 {
                            Text("+\(window.terminals.count - 3) more")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(8)
                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
                }
            }

            Spacer(minLength: 0)

            Text("Updated \(entry.snapshot.date, style: .relative) ago")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 4)
    }
}
#endif

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
