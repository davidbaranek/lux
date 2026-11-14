import Foundation

/// How the list and the chat write a time: "14:05", "Yesterday", "Tuesday", "3. 11. 2026".
public enum TimeText {
    public static func list(_ date: Date?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let date else { return "" }
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .numeric, time: .omitted)
    }

    /// A time to come, with its day: "20:00", "Tomorrow 9:00", "Monday 9:00", "24. 11. 9:00".
    public static func upcoming(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow \(time)") }
        if let days = calendar.dateComponents([.day], from: now, to: date).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide)) + " " + time
        }
        return date.formatted(.dateTime.day().month(.defaultDigits)) + " " + time
    }

    /// A length of time as a player shows it: "0:12", "1:05", "1:02:03".
    public static func duration(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func message(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// A day separator in a chat: "Today", "Yesterday", "Tuesday", "3 November 2026".
    public static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return String(localized: "Today") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(date: .long, time: .omitted)
    }
}

/// Someone typing in the open chat.
public struct Typist: Hashable, Sendable {
    public var name: String
    public var avatar: ImageRef?
    public init(name: String, avatar: ImageRef?) { self.name = name; self.avatar = avatar }
}

/// "Anna is typing…", "Anna and Petr are typing…", "Several people are typing…".
public enum TypingText {
    public static func text(_ names: [String]) -> String? {
        switch names.count {
        case 0: nil
        case 1: String(localized: "\(names[0]) is typing…")
        case 2: String(localized: "\(names[0]) and \(names[1]) are typing…")
        default: String(localized: "Several people are typing…")
        }
    }
}
