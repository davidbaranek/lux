import Foundation

/// How the list and the chat write a time: "14:05", "Yesterday", "Tuesday", "3. 11. 2026". Days
/// are `calendar`'s, in its time zone, counted from `now`; the words and numbers are `locale`'s.
public enum TimeText {
    public static func list(_ date: Date?, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        guard let date else { return "" }
        return switch days(from: date, to: now, calendar) {
        case 0: style(calendar, locale, date: .omitted, time: .shortened).format(date)
        case 1: String(localized: "Yesterday")
        case ..<7: style(calendar, locale).weekday(.wide).format(date)
        default: style(calendar, locale, date: .numeric, time: .omitted).format(date)
        }
    }

    /// A time to come, with its day: "20:00", "Tomorrow 9:00", "Monday 9:00", "24. 11. 9:00".
    public static func upcoming(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        let time = style(calendar, locale, date: .omitted, time: .shortened).format(date)
        return switch days(from: now, to: date, calendar) {
        case 0: time
        case 1: String(localized: "Tomorrow \(time)")
        case ..<7: style(calendar, locale).weekday(.wide).format(date) + " " + time
        default: style(calendar, locale).day().month(.defaultDigits).format(date) + " " + time
        }
    }

    /// A length of time as a player shows it: "0:12", "1:05", "1:02:03".
    public static func duration(_ seconds: Int) -> String {
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    public static func message(_ date: Date, calendar: Calendar = .current, locale: Locale = .current) -> String {
        style(calendar, locale, date: .omitted, time: .shortened).format(date)
    }

    /// A day separator in a chat: "Today", "Yesterday", "Tuesday", "3 November 2026".
    public static func day(_ date: Date, now: Date = .now, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch days(from: date, to: now, calendar) {
        case 0: String(localized: "Today")
        case 1: String(localized: "Yesterday")
        case ..<7: style(calendar, locale).weekday(.wide).format(date)
        default: style(calendar, locale, date: .long, time: .omitted).format(date)
        }
    }

    /// How many of the calendar's days `later` is after `earlier`: one from 23:59 to 0:01.
    private static func days(from earlier: Date, to later: Date, _ calendar: Calendar) -> Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: earlier), to: calendar.startOfDay(for: later)).day ?? 0
    }

    /// How `locale` writes a date of `calendar`, in the calendar's time zone.
    private static func style(_ calendar: Calendar, _ locale: Locale, date: Date.FormatStyle.DateStyle? = nil,
                              time: Date.FormatStyle.TimeStyle? = nil) -> Date.FormatStyle {
        Date.FormatStyle(date: date, time: time, locale: locale, calendar: calendar, timeZone: calendar.timeZone)
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
