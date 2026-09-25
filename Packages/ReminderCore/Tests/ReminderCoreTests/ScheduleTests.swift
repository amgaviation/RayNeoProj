import XCTest
@testable import ReminderCore

final class ScheduleTests: XCTestCase {
    private let newYork = "America/New_York"

    private func date(_ string: String, zone: String = "America/New_York") -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        guard let date = formatter.date(from: string) else {
            XCTFail("Bad date literal \(string)")
            return Date()
        }
        return date
    }

    private func local(_ date: Date, zone: String = "America/New_York") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm EEE"
        return formatter.string(from: date)
    }

    func testOnceHasSingleOccurrence() {
        let start = date("2026-10-01 09:00")
        let schedule = Schedule(frequency: .once, start: start, timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.allOccurrences(limit: 10), [start])
        XCTAssertEqual(schedule.nextOccurrence(after: start.addingTimeInterval(-60)), start)
        XCTAssertNil(schedule.nextOccurrence(after: start))
        XCTAssertTrue(schedule.isFinished(after: start))
    }

    func testDailyKeepsWallClockAcrossSpringForward() {
        // DST starts 2027-03-14 in the US.
        let schedule = Schedule(frequency: .daily, start: date("2027-03-12 09:00"), timeZoneIdentifier: newYork)
        let dates = schedule.allOccurrences(limit: 4).map { local($0) }
        XCTAssertEqual(dates, [
            "2027-03-12 09:00 Fri",
            "2027-03-13 09:00 Sat",
            "2027-03-14 09:00 Sun",
            "2027-03-15 09:00 Mon",
        ])
    }

    func testDailyKeepsWallClockAcrossFallBack() {
        // DST ends 2026-11-01 in the US.
        let schedule = Schedule(frequency: .daily, start: date("2026-10-31 18:30"), timeZoneIdentifier: newYork)
        let dates = schedule.allOccurrences(limit: 3).map { local($0) }
        XCTAssertEqual(dates, [
            "2026-10-31 18:30 Sat",
            "2026-11-01 18:30 Sun",
            "2026-11-02 18:30 Mon",
        ])
    }

    func testDailyInterval() {
        let schedule = Schedule(frequency: .daily, start: date("2026-10-01 07:15"), interval: 3, timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.allOccurrences(limit: 3).map { local($0) }, [
            "2026-10-01 07:15 Thu",
            "2026-10-04 07:15 Sun",
            "2026-10-07 07:15 Wed",
        ])
    }

    func testWeeklyMultipleDaysSkipsDaysBeforeStart() {
        // 2026-10-07 is a Wednesday. Mon (2) is before the start in week one.
        let schedule = Schedule(
            frequency: .weekly,
            start: date("2026-10-07 10:00"),
            weekdays: [2, 4, 6],
            timeZoneIdentifier: newYork
        )
        XCTAssertEqual(schedule.allOccurrences(limit: 5).map { local($0) }, [
            "2026-10-07 10:00 Wed",
            "2026-10-09 10:00 Fri",
            "2026-10-12 10:00 Mon",
            "2026-10-14 10:00 Wed",
            "2026-10-16 10:00 Fri",
        ])
    }

    func testWeeklyStartAfterSelectedDaysBeginsNextWeek() {
        // Thursday start, only Monday selected.
        let schedule = Schedule(
            frequency: .weekly,
            start: date("2026-10-08 08:00"),
            weekdays: [2],
            timeZoneIdentifier: newYork
        )
        XCTAssertEqual(schedule.allOccurrences(limit: 2).map { local($0) }, [
            "2026-10-12 08:00 Mon",
            "2026-10-19 08:00 Mon",
        ])
    }

    func testWeeklyEveryOtherWeek() {
        let schedule = Schedule(
            frequency: .weekly,
            start: date("2026-10-05 17:00"),
            interval: 2,
            weekdays: [2],
            timeZoneIdentifier: newYork
        )
        XCTAssertEqual(schedule.allOccurrences(limit: 3).map { local($0) }, [
            "2026-10-05 17:00 Mon",
            "2026-10-19 17:00 Mon",
            "2026-11-02 17:00 Mon",
        ])
    }

    func testWeeklyDefaultsToStartWeekday() {
        let schedule = Schedule(frequency: .weekly, start: date("2026-10-07 10:00"), timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.effectiveWeekdays, [4])
        XCTAssertEqual(schedule.allOccurrences(limit: 2).map { local($0) }, [
            "2026-10-07 10:00 Wed",
            "2026-10-14 10:00 Wed",
        ])
    }

    func testMonthlyClampsWithoutDrift() {
        let schedule = Schedule(frequency: .monthly, start: date("2027-01-31 12:00"), timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.allOccurrences(limit: 4).map { local($0) }, [
            "2027-01-31 12:00 Sun",
            "2027-02-28 12:00 Sun",
            "2027-03-31 12:00 Wed",
            "2027-04-30 12:00 Fri",
        ])
    }

    func testYearlyLeapDay() {
        let schedule = Schedule(frequency: .yearly, start: date("2028-02-29 09:00"), timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.allOccurrences(limit: 2).map { local($0) }, [
            "2028-02-29 09:00 Tue",
            "2029-02-28 09:00 Wed",
        ])
    }

    func testHourlyUsesAbsoluteHours() {
        let start = date("2026-10-01 08:00")
        let schedule = Schedule(frequency: .hourly, start: start, interval: 4, timeZoneIdentifier: newYork)
        let dates = schedule.allOccurrences(limit: 3)
        XCTAssertEqual(dates, [start, start.addingTimeInterval(4 * 3_600), start.addingTimeInterval(8 * 3_600)])
    }

    func testEndAfterCount() {
        let schedule = Schedule(frequency: .daily, start: date("2026-10-01 09:00"), end: .after(3), timeZoneIdentifier: newYork)
        XCTAssertEqual(schedule.allOccurrences(limit: 10).count, 3)
    }

    func testEndOnDateIsInclusive() {
        let schedule = Schedule(
            frequency: .daily,
            start: date("2026-10-01 09:00"),
            end: .on(date("2026-10-03 09:00")),
            timeZoneIdentifier: newYork
        )
        XCTAssertEqual(schedule.allOccurrences(limit: 10).count, 3)
    }

    func testWindowQueryMatchesBruteForce() {
        let schedules: [Schedule] = [
            Schedule(frequency: .hourly, start: date("2024-01-01 00:30"), interval: 5, timeZoneIdentifier: newYork),
            Schedule(frequency: .daily, start: date("2024-01-01 09:00"), interval: 2, timeZoneIdentifier: newYork),
            Schedule(frequency: .weekly, start: date("2024-01-03 09:00"), interval: 3, weekdays: [1, 3, 7], timeZoneIdentifier: newYork),
            Schedule(frequency: .monthly, start: date("2024-01-31 09:00"), interval: 2, timeZoneIdentifier: newYork),
            Schedule(frequency: .yearly, start: date("2020-02-29 09:00"), timeZoneIdentifier: newYork),
            Schedule(frequency: .weekly, start: date("2024-01-03 09:00"), weekdays: [2, 5], end: .after(150), timeZoneIdentifier: newYork),
            Schedule(frequency: .daily, start: date("2024-01-01 09:00"), end: .after(700), timeZoneIdentifier: newYork),
        ]
        let lower = date("2026-02-10 00:00")
        let upper = date("2026-05-20 00:00")
        for schedule in schedules {
            let brute = schedule.allOccurrences(limit: 100_000).filter { $0 >= lower && $0 <= upper }
            let windowed = schedule.occurrences(from: lower, through: upper, limit: 100_000)
            XCTAssertEqual(windowed, brute, "Mismatch for \(schedule.frequency)")
        }
    }

    func testNextOccurrenceAfterLongHistory() {
        let schedule = Schedule(frequency: .hourly, start: date("2020-01-01 00:00"), timeZoneIdentifier: newYork)
        let now = date("2026-10-01 10:20")
        XCTAssertEqual(schedule.nextOccurrence(after: now).map { local($0) }, "2026-10-01 11:00 Thu")
    }

    func testCountEndRespectedAfterSkippingAhead() {
        let schedule = Schedule(frequency: .daily, start: date("2026-01-01 09:00"), end: .after(10), timeZoneIdentifier: newYork)
        XCTAssertNil(schedule.nextOccurrence(after: date("2026-01-10 10:00")))
        XCTAssertEqual(schedule.nextOccurrence(after: date("2026-01-09 10:00")).map { local($0) }, "2026-01-10 09:00 Sat")
    }

    func testUpcoming() {
        let schedule = Schedule(frequency: .daily, start: date("2026-10-01 09:00"), timeZoneIdentifier: newYork)
        let upcoming = schedule.upcoming(from: date("2026-10-05 09:00"), count: 2).map { local($0) }
        XCTAssertEqual(upcoming, ["2026-10-05 09:00 Mon", "2026-10-06 09:00 Tue"])
    }

    func testCodingRoundTrip() {
        let schedules: [Schedule] = [
            Schedule(frequency: .weekly, start: date("2026-10-07 10:00"), interval: 2, weekdays: [2, 4], end: .after(5), timeZoneIdentifier: newYork),
            Schedule(frequency: .monthly, start: date("2026-10-07 10:00"), end: .on(date("2027-10-07 10:00")), timeZoneIdentifier: "Europe/London"),
            Schedule(frequency: .once, start: date("2026-10-07 10:00"), timeZoneIdentifier: newYork),
        ]
        for schedule in schedules {
            let json = ScheduleCoding.encode(schedule)
            XCTAssertFalse(json.isEmpty)
            XCTAssertEqual(ScheduleCoding.decode(json), schedule)
        }
    }

    func testDecodingToleratesMissingAndUnknownFields() {
        let json = #"{"start": 1790000000, "frequency": "fortnightly", "extra": true}"#
        let schedule = ScheduleCoding.decode(json)
        XCTAssertEqual(schedule?.frequency, .once)
        XCTAssertEqual(schedule?.interval, 1)
        XCTAssertEqual(schedule?.end, .never)
        XCTAssertNil(ScheduleCoding.decode(""))
        XCTAssertNil(ScheduleCoding.decode("not json"))
    }

    func testTruncatedToMinute() {
        let start = date("2026-10-01 09:00").addingTimeInterval(42.7)
        let schedule = Schedule(frequency: .daily, start: start, timeZoneIdentifier: newYork).truncatedToMinute()
        XCTAssertEqual(schedule.start, date("2026-10-01 09:00"))
    }

    func testSummaries() {
        let locale = Locale(identifier: "en_US")
        let weekly = Schedule(frequency: .weekly, start: date("2026-10-07 10:00"), interval: 2, weekdays: [2, 4], end: .after(5), timeZoneIdentifier: newYork)
        XCTAssertEqual(weekly.summary(locale: locale), "Every 2 weeks on Mon, Wed at 10:00 AM, 5 times")

        let daily = Schedule(frequency: .daily, start: date("2026-10-07 18:30"), timeZoneIdentifier: newYork)
        XCTAssertEqual(daily.summary(locale: locale), "Every day at 6:30 PM")

        let monthly = Schedule(frequency: .monthly, start: date("2026-10-15 09:00"), timeZoneIdentifier: newYork)
        XCTAssertEqual(monthly.summary(locale: locale), "Monthly on day 15 at 9:00 AM")

        let once = Schedule(frequency: .once, start: date("2026-10-15 09:00"), timeZoneIdentifier: newYork)
        XCTAssertTrue(once.summary(locale: locale).hasPrefix("Once on "))
        XCTAssertTrue(once.summary(locale: locale).hasSuffix("at 9:00 AM"))
    }

    func testValidationIssues() {
        let now = date("2026-10-10 12:00")
        let past = Schedule(frequency: .once, start: date("2026-10-01 09:00"), timeZoneIdentifier: newYork)
        XCTAssertFalse(past.validationIssues(now: now).isEmpty)

        let fine = Schedule(frequency: .daily, start: date("2026-10-01 09:00"), timeZoneIdentifier: newYork)
        XCTAssertTrue(fine.validationIssues(now: now).isEmpty)

        let backwards = Schedule(frequency: .daily, start: date("2026-10-11 09:00"), end: .on(date("2026-10-05 09:00")), timeZoneIdentifier: newYork)
        XCTAssertFalse(backwards.validationIssues(now: now).isEmpty)
    }
}

final class ActiveHoursTests: XCTestCase {
    private func date(_ string: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Denver")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: string)!
    }

    private func local(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Denver")
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    func testHourlyStaysInsideTheWindow() {
        let schedule = Schedule(
            frequency: .hourly,
            start: date("2026-10-01 07:00"),
            interval: 2,
            timeZoneIdentifier: "America/Denver",
            activeMinutes: (9 * 60)...(21 * 60)
        )
        let first = schedule.allOccurrences(limit: 8).map(local)
        XCTAssertEqual(first, [
            "10-01 09:00", "10-01 11:00", "10-01 13:00", "10-01 15:00",
            "10-01 17:00", "10-01 19:00", "10-01 21:00", "10-02 09:00",
        ])
        XCTAssertEqual(schedule.nextOccurrence(after: date("2026-10-05 21:30")).map(local), "10-06 09:00")
    }

    func testWindowOnlyAppliesToHourly() {
        let daily = Schedule(frequency: .daily, start: date("2026-10-01 06:00"), timeZoneIdentifier: "America/Denver", activeMinutes: 540...1_260)
        XCTAssertEqual(daily.allOccurrences(limit: 1).map(local), ["10-01 06:00"])
    }

    func testWindowRoundTripsThroughJSON() {
        let schedule = Schedule(frequency: .hourly, start: date("2026-10-01 07:00"), timeZoneIdentifier: "America/Denver", activeMinutes: 540...1_260)
        XCTAssertEqual(ScheduleCoding.decode(ScheduleCoding.encode(schedule))?.activeMinutes, 540...1_260)
        let plain = Schedule(frequency: .hourly, start: date("2026-10-01 07:00"), timeZoneIdentifier: "America/Denver")
        XCTAssertNil(ScheduleCoding.decode(ScheduleCoding.encode(plain))?.activeMinutes)
    }

    func testSummaryMentionsTheWindow() {
        let schedule = Schedule(frequency: .hourly, start: date("2026-10-01 07:00"), interval: 2, timeZoneIdentifier: "America/Denver", activeMinutes: 540...1_260)
        XCTAssertEqual(schedule.summary(locale: Locale(identifier: "en_US")), "Every 2 hours, 9:00 AM–9:00 PM")
    }
}
