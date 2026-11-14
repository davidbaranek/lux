import Foundation

/// A message the user saved, as the Saved list shows it.
public struct SavedMessage: Sendable, Hashable, Identifiable {
    /// The message's event id.
    public var id: String
    public var roomId: String
    public var senderName: String
    public var isOwn: Bool
    /// Its text or caption.
    public var body: String
    public var date: Date
    public var savedAt: Date
    public init(id: String, roomId: String, senderName: String, isOwn: Bool, body: String, date: Date, savedAt: Date) {
        self.id = id; self.roomId = roomId; self.senderName = senderName; self.isOwn = isOwn
        self.body = body; self.date = date; self.savedAt = savedAt
    }
}

/// A message that waits on the server and goes at its time, the phone off or not.
public struct ScheduledMessage: Sendable, Hashable, Identifiable {
    public var id: String
    public var roomId: String
    public var body: String
    public var sendAt: Date
    public init(id: String, roomId: String, body: String, sendAt: Date) { self.id = id; self.roomId = roomId; self.body = body; self.sendAt = sendAt }
}

/// The times a reminder or a later send offers: soon, this evening, tomorrow morning, next week.
public enum LaterTime: CaseIterable, Sendable {
    case inAnHour, thisEvening, tomorrowMorning, nextWeek

    /// The choices that make sense now: "this evening" only before it.
    public static func offered(at now: Date = .now, calendar: Calendar = .current) -> [LaterTime] {
        allCases.filter { $0.date(from: now, calendar: calendar) > now.addingTimeInterval(30 * 60) }
    }

    public func date(from now: Date = .now, calendar: Calendar = .current) -> Date {
        switch self {
        case .inAnHour: now.addingTimeInterval(3600)
        case .thisEvening: calendar.date(bySettingHour: 20, minute: 0, second: 0, of: now) ?? now
        case .tomorrowMorning:
            calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: now) ?? now) ?? now
        case .nextWeek:
            calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: calendar.firstWeekday == 1 ? 2 : calendar.firstWeekday),
                              matchingPolicy: .nextTime) ?? now
        }
    }

    public var title: String {
        switch self {
        case .inAnHour: String(localized: "In an Hour")
        case .thisEvening: String(localized: "This Evening")
        case .tomorrowMorning: String(localized: "Tomorrow Morning")
        case .nextWeek: String(localized: "Next Week")
        }
    }

    public var symbol: String {
        switch self {
        case .inAnHour: "clock"
        case .thisEvening: "moon"
        case .tomorrowMorning: "sunrise"
        case .nextWeek: "calendar"
        }
    }
}

extension SavedMessage {
    /// What a row id of the Saved list starts with (the message's event id follows).
    public static let rowPrefix = "saved:"

    /// The saved message as a list row: its chat's name and picture, who wrote it and what.
    public func row(in chat: ChatRow?) -> ChatRow {
        var row = chat ?? ChatRow(id: roomId, name: String(localized: "Chat"), preview: "", date: nil)
        row.id = Self.rowPrefix + id
        row.preview = isOwn ? String(localized: "You: ") + body : (senderName.isEmpty ? body : senderName + ": " + body)
        row.date = date
        row.unreadCount = 0
        row.isMarkedUnread = false
        row.isPinned = false
        row.reminder = nil
        return row
    }
}

extension ScheduledMessage {
    public static let rowPrefix = "scheduled:"

    /// The waiting message as a list row: its chat, when it goes, and its text.
    public func row(in chat: ChatRow?) -> ChatRow {
        var row = chat ?? ChatRow(id: roomId, name: String(localized: "Chat"), preview: "", date: nil)
        row.id = Self.rowPrefix + id
        row.preview = String(localized: "Sends \(TimeText.upcoming(sendAt)) · ") + body
        row.date = nil
        row.unreadCount = 0
        row.isMarkedUnread = false
        row.isPinned = false
        row.reminder = nil
        return row
    }
}
