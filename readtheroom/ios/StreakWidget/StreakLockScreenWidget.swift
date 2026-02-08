//
//  StreakLockScreenWidget.swift
//  StreakWidget
//
//  Lock screen widget for Read the Room app.
//  Shows streak count with app logo. Appears as a separate
//  entry in the widget picker from the home screen widget.
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct LockScreenEntry: TimelineEntry {
    let date: Date
    let streakCount: Int
}

// MARK: - Timeline Provider

struct LockScreenProvider: TimelineProvider {
    func placeholder(in context: Context) -> LockScreenEntry {
        LockScreenEntry(date: Date(), streakCount: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (LockScreenEntry) -> ()) {
        let ud = UserDefaults(suiteName: "group.com.readtheroom.app")
        let count = ud?.integer(forKey: "streak_count") ?? 0
        completion(LockScreenEntry(date: Date(), streakCount: count))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LockScreenEntry>) -> ()) {
        let ud = UserDefaults(suiteName: "group.com.readtheroom.app")
        let count = ud?.integer(forKey: "streak_count") ?? 0
        let entry = LockScreenEntry(date: Date(), streakCount: count)

        // Reload every hour or when the app updates the widget
        let nextUpdate = Date().addingTimeInterval(3600)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }
}

// MARK: - Lock Screen Widget View

struct StreakLockScreenWidgetView: View {
    var entry: LockScreenEntry
    @Environment(\.widgetFamily) var widgetFamily

    var body: some View {
        switch widgetFamily {
        case .accessoryRectangular:
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 32))

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.streakCount)")
                        .font(.system(size: 26, weight: .bold))
                    Text("answer streak")
                        .font(.system(size: 12))
                        .opacity(0.8)
                }
            }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()

                VStack(spacing: 1) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 14))

                    Text("\(entry.streakCount)")
                        .font(.system(size: 16, weight: .bold))
                }
            }
        case .accessoryInline:
            HStack(spacing: 4) {
                Image(systemName: "flame.fill")
                Text("\(entry.streakCount) · Read the Room")
            }
        default:
            Text("\(entry.streakCount)")
        }
    }
}

// MARK: - Widget Configuration

struct StreakLockScreenWidget: Widget {
    let kind: String = "StreakLockScreenWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LockScreenProvider()) { entry in
            StreakLockScreenWidgetView(entry: entry)
                .containerBackground(.blue, for: .widget)
                .widgetURL(URL(string: "readtheroom://home"))
        }
        .configurationDisplayName("Streak")
        .description("Track your answer streak on your lock screen")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
        ])
    }
}
