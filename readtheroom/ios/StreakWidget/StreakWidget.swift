//
//  StreakWidget.swift
//  StreakWidget
//
//  Home screen widget for Read the Room app.
//  Small (2x2): Streak count with Curio
//  Medium (4x2): Question of the Day with Curio
//

import WidgetKit
import SwiftUI

// MARK: - Timeline Entry

struct StreakEntry: TimelineEntry {
    let date: Date
    // Streak data
    let streakCount: Int
    let curioState: String
    let colorHex: Int
    // QOTD data
    let questionText: String
    let voteCount: Int
    let commentCount: Int
    let hasAnswered: Bool
    let questionId: String
}

// MARK: - Timeline Provider

struct Provider: TimelineProvider {
    private let appGroupId = "group.com.readtheroom.app"

    func placeholder(in context: Context) -> StreakEntry {
        StreakEntry(date: Date(), streakCount: 0, curioState: "neutral", colorHex: 0x00897B,
                   questionText: "What's on your mind?", voteCount: 0, commentCount: 0, hasAnswered: false, questionId: "")
    }

    func getSnapshot(in context: Context, completion: @escaping (StreakEntry) -> ()) {
        let entry = buildEntry(for: Date())
        completion(entry)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StreakEntry>) -> ()) {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)

        let userDefaults = UserDefaults(suiteName: appGroupId)
        let streakCount = userDefaults?.integer(forKey: "streak_count") ?? 0
        let hasExtendedTodayStored = userDefaults?.bool(forKey: "has_extended_today") ?? false
        let lastUpdated = userDefaults?.string(forKey: "last_updated")
        let hasExtendedToday = hasExtendedTodayStored && wasUpdatedToday(lastUpdated)

        // QOTD data
        let questionText = userDefaults?.string(forKey: "qotd_question_text") ?? "What's on your mind?"
        let voteCount = userDefaults?.integer(forKey: "qotd_vote_count") ?? 0
        let commentCount = userDefaults?.integer(forKey: "qotd_comment_count") ?? 0
        let hasAnswered = userDefaults?.bool(forKey: "qotd_has_answered") ?? false
        let questionId = userDefaults?.string(forKey: "qotd_question_id") ?? ""

        var entries: [StreakEntry] = []

        let currentState = calculateCurioState(streakCount: streakCount, hasExtendedToday: hasExtendedToday, hoursRemaining: getHoursRemaining(at: now))
        entries.append(StreakEntry(date: now, streakCount: streakCount, curioState: currentState, colorHex: calculateColorHex(currentState),
                                   questionText: questionText, voteCount: voteCount, commentCount: commentCount, hasAnswered: hasAnswered, questionId: questionId))

        let thresholdHours = [(16, 0), (21, 0), (23, 0)]
        for (hour, minute) in thresholdHours {
            if let thresholdDate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: today),
               thresholdDate > now {
                let state = calculateCurioState(streakCount: streakCount, hasExtendedToday: hasExtendedToday, hoursRemaining: getHoursRemaining(at: thresholdDate))
                entries.append(StreakEntry(date: thresholdDate, streakCount: streakCount, curioState: state, colorHex: calculateColorHex(state),
                                           questionText: questionText, voteCount: voteCount, commentCount: commentCount, hasAnswered: hasAnswered, questionId: questionId))
            }
        }

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let midnightDate = calendar.date(bySettingHour: 0, minute: 0, second: 1, of: tomorrow)!
        let midnightState = calculateCurioState(streakCount: streakCount, hasExtendedToday: false, hoursRemaining: getHoursRemaining(at: midnightDate))
        entries.append(StreakEntry(date: midnightDate, streakCount: streakCount, curioState: midnightState, colorHex: calculateColorHex(midnightState),
                                   questionText: questionText, voteCount: voteCount, commentCount: commentCount, hasAnswered: hasAnswered, questionId: questionId))

        let timeline = Timeline(entries: entries, policy: .after(midnightDate))
        completion(timeline)
    }

    private func buildEntry(for date: Date) -> StreakEntry {
        let userDefaults = UserDefaults(suiteName: appGroupId)
        let streakCount = userDefaults?.integer(forKey: "streak_count") ?? 0
        let hasExtendedTodayStored = userDefaults?.bool(forKey: "has_extended_today") ?? false
        let lastUpdated = userDefaults?.string(forKey: "last_updated")
        let hasExtendedToday = hasExtendedTodayStored && wasUpdatedToday(lastUpdated)
        let hoursRemaining = getHoursRemaining(at: date)
        let curioState = calculateCurioState(streakCount: streakCount, hasExtendedToday: hasExtendedToday, hoursRemaining: hoursRemaining)

        let questionText = userDefaults?.string(forKey: "qotd_question_text") ?? "What's on your mind?"
        let voteCount = userDefaults?.integer(forKey: "qotd_vote_count") ?? 0
        let commentCount = userDefaults?.integer(forKey: "qotd_comment_count") ?? 0
        let hasAnswered = userDefaults?.bool(forKey: "qotd_has_answered") ?? false
        let questionId = userDefaults?.string(forKey: "qotd_question_id") ?? ""

        return StreakEntry(date: date, streakCount: streakCount, curioState: curioState, colorHex: calculateColorHex(curioState),
                          questionText: questionText, voteCount: voteCount, commentCount: commentCount, hasAnswered: hasAnswered, questionId: questionId)
    }

    private func getHoursRemaining(at date: Date) -> Double {
        let calendar = Calendar.current
        var endOfDay = DateComponents()
        endOfDay.hour = 23
        endOfDay.minute = 59
        endOfDay.second = 59
        let endOfDayDate = calendar.nextDate(after: calendar.startOfDay(for: date), matching: endOfDay, matchingPolicy: .nextTime)
            ?? calendar.date(bySettingHour: 23, minute: 59, second: 59, of: date)!
        let minutesRemaining = calendar.dateComponents([.minute], from: date, to: endOfDayDate).minute ?? 0
        return Double(max(minutesRemaining, 0)) / 60.0
    }

    private func wasUpdatedToday(_ lastUpdatedStr: String?) -> Bool {
        guard let str = lastUpdatedStr, !str.isEmpty else { return false }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let todayPrefix = formatter.string(from: Date())
        return str.hasPrefix(todayPrefix)
    }

    private func calculateCurioState(streakCount: Int, hasExtendedToday: Bool, hoursRemaining: Double) -> String {
        if streakCount == 0 { return "dread" }
        if hasExtendedToday { return "happy" }
        if hoursRemaining < 1 { return "critical" }
        if hoursRemaining < 3 { return "angry" }
        if hoursRemaining < 8 { return "sad" }
        return "neutral"
    }

    private func calculateColorHex(_ curioState: String) -> Int {
        switch curioState {
        case "happy", "neutral": return 0x00897B
        case "sad":              return 0xEA6D32
        case "angry", "critical": return 0x951414
        case "dread":            return 0x9E9E9E
        default:                 return 0x00897B
        }
    }
}

// MARK: - Widget View

struct StreakWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var curioImageName: String {
        switch entry.curioState {
        case "happy", "neutral": return "curio_happy"
        case "sad":              return "curio_sad"
        case "angry":            return "curio_angry"
        case "critical", "dread": return "curio_dread"
        default:                 return "curio_happy"
        }
    }

    var qotdCurioImageName: String {
        entry.hasAnswered ? "curio_happy" : "curio_questioning"
    }

    var body: some View {
        switch family {
        case .systemMedium:
            // QOTD Layout - Curio 1/4 width centered, text 3/4 width
            GeometryReader { geo in
                HStack(spacing: 0) {
                    // Curio container - 1/4 width, curio fills it
                    Image(qotdCurioImageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: geo.size.width * 0.28, height: geo.size.height)
                        .frame(width: geo.size.width * 0.25)

                    // Text container - 3/4 width
                    VStack(alignment: .leading, spacing: 10) {
                        Text(String(entry.questionText.prefix(120)))
                            .font(.system(size: 17, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(3)

                        if let stats = statsText {
                            Text(stats)
                                .font(.system(size: 14))
                                .foregroundColor(.white.opacity(0.8))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 4)
                    .padding(.trailing, 6)
                }
            }
            .padding(8)
            .widgetURL(URL(string: entry.questionId.isEmpty ? "readtheroom://home" : "readtheroom://qotd/\(entry.questionId)"))
        default:
            // Streak Layout (small)
            GeometryReader { geo in
                VStack(spacing: 2) {
                    Image(curioImageName)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: geo.size.height * 0.75)

                    HStack(spacing: 3) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(.white)
                        Text("\(entry.streakCount)")
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(6)
            .widgetURL(URL(string: "readtheroom://home"))
        }
    }

    // Only show votes if > 10, comments if > 0
    var statsText: String? {
        var parts: [String] = []

        if entry.voteCount > 10 {
            parts.append("\(entry.voteCount) \(entry.voteCount == 1 ? "vote" : "votes")")
        }

        if entry.commentCount > 0 {
            parts.append("\(entry.commentCount) \(entry.commentCount == 1 ? "comment" : "comments")")
        }

        return parts.isEmpty ? nil : parts.joined(separator: " • ")
    }
}

// MARK: - Widget Container (handles background based on size)

struct StreakWidgetContainer: View {
    @Environment(\.widgetFamily) var family
    var entry: Provider.Entry

    var backgroundColor: Color {
        switch family {
        case .systemMedium:
            // Always teal for QOTD
            return Color(hex: 0x00897B)
        default:
            return Color(hex: entry.colorHex)
        }
    }

    var body: some View {
        StreakWidgetEntryView(entry: entry)
            .containerBackground(backgroundColor, for: .widget)
    }
}

// MARK: - Widget Configuration

struct StreakWidget: Widget {
    let kind: String = "StreakWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: Provider()) { entry in
            StreakWidgetContainer(entry: entry)
        }
        .configurationDisplayName("Read the Room")
        .description("Streak and Question of the Day")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

// MARK: - Color Extension

extension Color {
    init(hex: Int) {
        let red = Double((hex >> 16) & 0xFF) / 255.0
        let green = Double((hex >> 8) & 0xFF) / 255.0
        let blue = Double(hex & 0xFF) / 255.0
        self.init(red: red, green: green, blue: blue)
    }
}
