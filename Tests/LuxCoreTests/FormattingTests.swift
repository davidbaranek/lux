import Foundation
import Testing
@testable import LuxCore

/// A calendar, time zone and language of the test's own: New York (its clocks went back on
/// 1 November 2026), weeks from Monday, in British English. None is the machine's.
private struct Fixed {
    let calendar: Calendar
    let locale = Locale(identifier: "en_GB")
    /// Tuesday 3 November 2026, 14:05 in New York.
    let now: Date

    init() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        calendar.locale = locale
        calendar.firstWeekday = 2
        self.calendar = calendar
        now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 14, minute: 5)))
    }

    /// `day` November 2026 (or of `month`) at `hour`:`minute`, in New York.
    func date(_ day: Int, month: Int = 11, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)))
    }
}

@Suite struct TimeTextTests {
    private let fixed: Fixed
    init() throws { fixed = try Fixed() }

    private func list(_ date: Date?, locale: Locale? = nil) -> String {
        TimeText.list(date, now: fixed.now, calendar: fixed.calendar, locale: locale ?? fixed.locale)
    }

    @Test func theListWritesTodaysTimeYesterdayThisWeeksDaysAndOlderDates() throws {
        #expect(list(nil) == "")
        #expect(list(fixed.now) == "14:05")
        #expect(list(try fixed.date(3, 10, 15)) == "10:15")
        #expect(list(try fixed.date(2, 23, 50)) == "Yesterday")
        #expect(list(try fixed.date(1, 9)) == "Sunday")
        #expect(list(try fixed.date(28, month: 10, 10)) == "Wednesday")
        #expect(list(try fixed.date(28, month: 10, 10), locale: Locale(identifier: "de_DE")) == "Mittwoch")
    }

    @Test func aMessageFromLastWeeksSameDayShowsItsDateNotTodaysName() throws {
        // under seven times 24 hours ago, but seven days back.
        #expect(list(try fixed.date(27, month: 10, 18)) == "27/10/2026")
    }

    @Test func theDayIsTheCalendarsInItsTimeZone() throws {
        // 04:30 in London is 23:30 the day before in New York.
        let lateLastNight = try #require(ISO8601DateFormatter().date(from: "2026-11-03T04:30:00Z"))
        #expect(list(lateLastNight) == "Yesterday")
        #expect(TimeText.day(lateLastNight, now: fixed.now, calendar: fixed.calendar, locale: fixed.locale) == "Yesterday")
        #expect(TimeText.message(lateLastNight, calendar: fixed.calendar, locale: fixed.locale) == "23:30")
    }

    @Test func aChatsDaySeparatorSaysTodayYesterdayTheDayOrTheDate() throws {
        func day(_ date: Date) -> String { TimeText.day(date, now: fixed.now, calendar: fixed.calendar, locale: fixed.locale) }
        #expect(day(try fixed.date(3, 0, 1)) == "Today")
        #expect(day(try fixed.date(2, 0, 1)) == "Yesterday")
        #expect(day(try fixed.date(30, month: 10, 12)) == "Friday")
        #expect(day(try fixed.date(27, month: 10, 12)) == "27 October 2026")
    }

    @Test func aTimeToComeSaysItsDayWhenItIsNotToday() throws {
        func upcoming(_ date: Date) -> String { TimeText.upcoming(date, now: fixed.now, calendar: fixed.calendar, locale: fixed.locale) }
        #expect(upcoming(try fixed.date(3, 20)) == "20:00")
        #expect(upcoming(try fixed.date(4, 10, 30)) == "Tomorrow 10:30")
        #expect(upcoming(try fixed.date(9, 10, 30)) == "Monday 10:30")
        #expect(upcoming(try fixed.date(10, 10, 30)) == "10/11 10:30")
    }

    @Test func aPlayerWritesMinutesAndSecondsAndHoursOnlyWhenThereAreSome() {
        #expect(TimeText.duration(12) == "0:12")
        #expect(TimeText.duration(65) == "1:05")
        #expect(TimeText.duration(3_723) == "1:02:03")
    }
}

@Suite struct LaterTimeTests {
    private let fixed: Fixed
    init() throws { fixed = try Fixed() }

    private func offered(at now: Date) -> [LaterTime] { LaterTime.offered(at: now, calendar: fixed.calendar) }
    private func date(_ time: LaterTime, from now: Date) -> Date { time.date(from: now, calendar: fixed.calendar) }

    @Test func eachChoiceIsItsTimeOnTheCalendar() throws {
        #expect(date(.inAnHour, from: fixed.now) == fixed.now.addingTimeInterval(3_600))
        #expect(date(.thisEvening, from: fixed.now) == (try fixed.date(3, 20)))
        #expect(date(.tomorrowMorning, from: fixed.now) == (try fixed.date(4, 9)))
        #expect(date(.nextWeek, from: fixed.now) == (try fixed.date(9, 9)))
    }

    @Test func thisEveningIsOfferedOnlyWhileItIsMoreThanHalfAnHourAway() throws {
        #expect(offered(at: fixed.now) == [.inAnHour, .thisEvening, .tomorrowMorning, .nextWeek])
        #expect(offered(at: try fixed.date(3, 19, 45)) == [.inAnHour, .tomorrowMorning, .nextWeek])
        #expect(offered(at: try fixed.date(3, 21)) == [.inAnHour, .tomorrowMorning, .nextWeek])
    }

    @Test func nextWeekOnAMondayMorningIsTheMondayAfterNotThatMorning() throws {
        #expect(date(.nextWeek, from: try fixed.date(9, 8)) == (try fixed.date(16, 9)))
        // on a Sunday, the next week starts tomorrow.
        #expect(date(.nextWeek, from: try fixed.date(8, 22)) == (try fixed.date(9, 9)))
    }

    @Test func nextWeekIsAMondayAlsoWhereWeeksStartOnSunday() throws {
        var calendar = fixed.calendar
        calendar.firstWeekday = 1
        #expect(LaterTime.nextWeek.date(from: fixed.now, calendar: calendar) == (try fixed.date(9, 9)))
    }
}

@Suite struct MonogramTests {
    @Test func theInitialsAreTheFirstLettersOfTheFirstTwoWords() {
        #expect(Monogram.initials("Anna Nováková") == "AN")
        #expect(Monogram.initials("jan-petr novák") == "JP")
        #expect(Monogram.initials("élan") == "É")
        // a word that starts with no letter (an emoji, a number) is skipped.
        #expect(Monogram.initials("😀 Anna 2 Bob") == "AB")
        #expect(Monogram.initials("") == "")
    }

    @Test func aNameHasTheSameColourOnEveryDevice() {
        // fixed by the name's letters alone, not by this process's hashing.
        #expect(Monogram.color("Anna Nováková") == .systemPink)
        #expect(Monogram.color("Bob") == .systemRed)
        #expect(Monogram.color("Petr Svoboda") == .systemPurple)
    }
}
