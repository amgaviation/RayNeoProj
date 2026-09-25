import Foundation

/// When a reminder fires. Stored as JSON (see `ScheduleCoding`) so new options
/// can be added later without a CloudKit schema change.
public struct Schedule: Equatable, Hashable, Sendable {
    public enum Frequency: String, Codable, CaseIterable, Identifiable, Sendable {
        case once, hourly, daily, weekly, monthly, yearly

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .once: return "Once"
            case .hourly: return "Hourly"
            case .daily: return "Daily"
            case .weekly: return "Weekly"
            case .monthly: return "Monthly"
            case .yearly: return "Yearly"
            }
        }

        /// "day" / "days" etc., for "Every N …" labels. Empty for `.once`.
        public func unit(plural: Bool) -> String {
            switch self {
            case .once: return ""
            case .hourly: return plural ? "hours" : "hour"
            case .daily: return plural ? "days" : "day"
            case .weekly: return plural ? "weeks" : "week"
            case .monthly: return plural ? "months" : "month"
            case .yearly: return plural ? "years" : "year"
            }
        }
    }

    public enum End: Equatable, Hashable, Sendable {
        case never
        /// No occurrences after this instant.
        case on(Date)
        /// Stop after this many occurrences in total.
        case after(Int)
    }

    public var frequency: Frequency
    /// The first occurrence. Its time of day is used for every later occurrence.
    public var start: Date
    /// Every N hours/days/weeks/months/years. Values below 1 behave as 1.
    public var interval: Int
    /// For `.weekly`: Calendar weekday numbers, 1 = Sunday … 7 = Saturday.
    /// Empty means "the weekday of `start`".
    public var weekdays: [Int]
    public var end: End
    /// Occurrences are computed in this zone so they keep their wall-clock time
    /// across DST changes and when the relay Mac sits in another zone.
    public var timeZoneIdentifier: String

    public init(
        frequency: Frequency = .once,
        start: Date,
        interval: Int = 1,
        weekdays: [Int] = [],
        end: End = .never,
        timeZoneIdentifier: String = TimeZone.current.identifier
    ) {
        self.frequency = frequency
        self.start = start
        self.interval = interval
        self.weekdays = weekdays
        self.end = end
        self.timeZoneIdentifier = timeZoneIdentifier
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .current
    }

    public var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    public var normalizedInterval: Int { max(1, interval) }

    /// Sorted, de-duplicated weekdays in 1...7, defaulting to the weekday of `start`.
    public var effectiveWeekdays: [Int] {
        let valid = Set(weekdays.filter { (1...7).contains($0) })
        if valid.isEmpty {
            return [calendar.component(.weekday, from: start)]
        }
        return valid.sorted()
    }

    /// A copy with seconds (and sub-seconds) dropped from `start`, so occurrence
    /// keys stay stable no matter when the picker produced the date.
    public func truncatedToMinute() -> Schedule {
        var copy = self
        let seconds = copy.start.timeIntervalSinceReferenceDate
        copy.start = Date(timeIntervalSinceReferenceDate: (seconds / 60).rounded(.down) * 60)
        return copy
    }

    /// Problems worth showing in an editor. Empty when the schedule is fine.
    public func validationIssues(now: Date = Date()) -> [String] {
        var issues: [String] = []
        if case .on(let endDate) = end, endDate < start {
            issues.append("The end date is before the first reminder.")
        }
        if case .after(let count) = end, count < 1 {
            issues.append("\"Stop after\" needs at least 1 time.")
        }
        if frequency == .once, start < now {
            issues.append("This one-time reminder is in the past, so it will never be sent.")
        }
        if frequency != .once, nextOccurrence(after: now) == nil {
            issues.append("This schedule has already finished.")
        }
        return issues
    }
}

// MARK: - Occurrences

extension Schedule {
    /// Occurrences within `[lower, upper]`, ascending, at most `limit` of them.
    public func occurrences(from lower: Date, through upper: Date, limit: Int = 1_000) -> [Date] {
        guard upper >= lower, limit > 0 else { return [] }
        var iterator = OccurrenceIterator(schedule: self, near: lower)
        var result: [Date] = []
        while let date = iterator.next() {
            if date > upper { break }
            if date >= lower {
                result.append(date)
                if result.count >= limit { break }
            }
        }
        return result
    }

    /// The first occurrence strictly after `date`, if the schedule has one.
    public func nextOccurrence(after date: Date) -> Date? {
        var iterator = OccurrenceIterator(schedule: self, near: date)
        while let candidate = iterator.next() {
            if candidate > date { return candidate }
        }
        return nil
    }

    /// Up to `count` occurrences at or after `date`.
    public func upcoming(from date: Date, count: Int) -> [Date] {
        guard count > 0 else { return [] }
        var iterator = OccurrenceIterator(schedule: self, near: date)
        var result: [Date] = []
        while let candidate = iterator.next() {
            if candidate >= date {
                result.append(candidate)
                if result.count >= count { break }
            }
        }
        return result
    }

    /// Every occurrence from the start, capped at `limit`. Handy for tests and previews.
    public func allOccurrences(limit: Int) -> [Date] {
        var iterator = OccurrenceIterator(schedule: self, near: nil)
        var result: [Date] = []
        while result.count < limit, let date = iterator.next() {
            result.append(date)
        }
        return result
    }

    /// True once no occurrence remains after `now`.
    public func isFinished(after now: Date) -> Bool {
        nextOccurrence(after: now) == nil
    }
}

/// Walks a schedule's occurrences in ascending order. When given a lower bound it
/// jumps close to it arithmetically, so a years-old hourly schedule stays cheap.
struct OccurrenceIterator: IteratorProtocol {
    private let schedule: Schedule
    private let calendar: Calendar
    private let interval: Int
    private let start: Date

    /// Global index (0-based) of the next occurrence to be returned.
    private var index = 0
    private var exhausted = false
    private var steps = 0
    private static let maxSteps = 250_000

    // Weekly state.
    private var weekdays: [Int] = []
    private var weekStart = Date()
    private var block = 0
    private var position = 0
    private var hour = 0
    private var minute = 0
    private var second = 0

    init(schedule: Schedule, near lower: Date?) {
        self.schedule = schedule
        self.calendar = schedule.calendar
        self.interval = schedule.normalizedInterval
        self.start = schedule.start

        let parts = calendar.dateComponents([.hour, .minute, .second], from: start)
        hour = parts.hour ?? 0
        minute = parts.minute ?? 0
        second = parts.second ?? 0

        if schedule.frequency == .weekly {
            weekdays = schedule.effectiveWeekdays
            let dayStart = calendar.startOfDay(for: start)
            let startWeekday = calendar.component(.weekday, from: start)
            weekStart = calendar.date(byAdding: .day, value: -(startWeekday - 1), to: dayStart) ?? dayStart
        }

        if let lower, lower > start {
            skipAhead(toward: lower)
        }
    }

    mutating func next() -> Date? {
        while !exhausted {
            steps += 1
            if steps > Self.maxSteps {
                exhausted = true
                return nil
            }
            if case .after(let count) = schedule.end, index >= count {
                exhausted = true
                return nil
            }
            guard let candidate = nextCandidate() else {
                exhausted = true
                return nil
            }
            if case .on(let endDate) = schedule.end, candidate > endDate {
                exhausted = true
                return nil
            }
            index += 1
            return candidate
        }
        return nil
    }

    /// Produces the occurrence at the current cursor and advances it.
    /// Returns nil when the frequency has nothing further (e.g. `.once`).
    private mutating func nextCandidate() -> Date? {
        switch schedule.frequency {
        case .once:
            return index == 0 ? start : nil
        case .hourly:
            return start.addingTimeInterval(TimeInterval(index * interval * 3_600))
        case .daily:
            return calendar.date(byAdding: .day, value: index * interval, to: start)
        case .monthly:
            return calendar.date(byAdding: .month, value: index * interval, to: start)
        case .yearly:
            return calendar.date(byAdding: .year, value: index * interval, to: start)
        case .weekly:
            return nextWeeklyCandidate()
        }
    }

    private mutating func nextWeeklyCandidate() -> Date? {
        while true {
            steps += 1
            if steps > Self.maxSteps { return nil }
            if position >= weekdays.count {
                block += 1
                position = 0
            }
            let weekday = weekdays[position]
            position += 1
            guard let date = weeklyDate(block: block, weekday: weekday) else { return nil }
            // Days earlier in the first week than the start itself do not count.
            if block == 0, date < start { continue }
            return date
        }
    }

    private func weeklyDate(block: Int, weekday: Int) -> Date? {
        let dayOffset = block * interval * 7 + (weekday - 1)
        guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart) else { return nil }
        return calendar.date(bySettingHour: hour, minute: minute, second: second, of: day)
    }

    /// Moves the cursor to just before `lower`, keeping `index` equal to the
    /// number of occurrences skipped so `.after(count)` stays exact.
    private mutating func skipAhead(toward lower: Date) {
        switch schedule.frequency {
        case .once:
            return
        case .hourly:
            let elapsed = lower.timeIntervalSince(start)
            let steps = Int(elapsed / TimeInterval(interval * 3_600))
            index = max(0, steps - 1)
        case .daily:
            let days = calendar.dateComponents([.day], from: start, to: lower).day ?? 0
            index = max(0, days / interval - 1)
        case .monthly:
            let months = calendar.dateComponents([.month], from: start, to: lower).month ?? 0
            index = max(0, months / interval - 1)
        case .yearly:
            let years = calendar.dateComponents([.year], from: start, to: lower).year ?? 0
            index = max(0, years / interval - 1)
        case .weekly:
            let days = calendar.dateComponents([.day], from: weekStart, to: lower).day ?? 0
            let targetBlock = max(0, days / (7 * interval) - 1)
            guard targetBlock > 0 else { return }
            // Occurrences in the first (possibly partial) week.
            var firstWeekCount = 0
            for weekday in weekdays {
                if let date = weeklyDate(block: 0, weekday: weekday), date >= start {
                    firstWeekCount += 1
                }
            }
            block = targetBlock
            position = 0
            index = firstWeekCount + (targetBlock - 1) * weekdays.count
        }
    }
}

// MARK: - Human-readable summary

extension Schedule {
    /// "Every 2 weeks on Mon, Wed at 9:00 AM, 10 times" and similar.
    public func summary(locale: Locale = .current) -> String {
        let time = Self.format(start, template: "jmm", locale: locale, timeZone: timeZone)
        let n = normalizedInterval
        var text: String

        switch frequency {
        case .once:
            let date = Self.format(start, template: "EEEMMMdyyyy", locale: locale, timeZone: timeZone)
            return "Once on \(date) at \(time)"
        case .hourly:
            text = n == 1 ? "Every hour" : "Every \(n) hours"
            text += " from \(time)"
        case .daily:
            text = n == 1 ? "Every day" : "Every \(n) days"
            text += " at \(time)"
        case .weekly:
            var symbolCalendar = calendar
            symbolCalendar.locale = locale
            let symbols = symbolCalendar.shortWeekdaySymbols
            let days = effectiveWeekdays.compactMap { symbols.indices.contains($0 - 1) ? symbols[$0 - 1] : nil }
            text = n == 1 ? "Every week" : "Every \(n) weeks"
            text += " on \(days.joined(separator: ", ")) at \(time)"
        case .monthly:
            let day = calendar.component(.day, from: start)
            text = n == 1 ? "Monthly" : "Every \(n) months"
            text += " on day \(day) at \(time)"
        case .yearly:
            let date = Self.format(start, template: "MMMd", locale: locale, timeZone: timeZone)
            text = n == 1 ? "Yearly" : "Every \(n) years"
            text += " on \(date) at \(time)"
        }

        switch end {
        case .never:
            break
        case .on(let endDate):
            text += ", until " + Self.format(endDate, template: "MMMdyyyy", locale: locale, timeZone: timeZone)
        case .after(let count):
            text += count == 1 ? ", 1 time" : ", \(count) times"
        }
        return text
    }

    static func format(_ date: Date, template: String, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(template)
        return TextCleanup.plainSpaces(formatter.string(from: date))
    }
}

enum TextCleanup {
    /// ICU puts narrow no-break spaces before AM/PM; keep message text plain.
    static func plainSpaces(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

// MARK: - Coding

extension Schedule.End: Codable {
    private enum CodingKeys: String, CodingKey { case type, date, count }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "never"
        switch type {
        case "on":
            self = .on(try container.decode(Date.self, forKey: .date))
        case "after":
            self = .after(try container.decode(Int.self, forKey: .count))
        default:
            self = .never
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .never:
            try container.encode("never", forKey: .type)
        case .on(let date):
            try container.encode("on", forKey: .type)
            try container.encode(date, forKey: .date)
        case .after(let count):
            try container.encode("after", forKey: .type)
            try container.encode(count, forKey: .count)
        }
    }
}

extension Schedule: Codable {
    private enum CodingKeys: String, CodingKey {
        case frequency, start, interval, weekdays, end, timeZoneIdentifier
    }

    /// Tolerant decoding: anything missing falls back to a default, so records
    /// written by an older or newer app version still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawFrequency = try container.decodeIfPresent(String.self, forKey: .frequency) ?? "once"
        frequency = Frequency(rawValue: rawFrequency) ?? .once
        start = try container.decode(Date.self, forKey: .start)
        interval = try container.decodeIfPresent(Int.self, forKey: .interval) ?? 1
        weekdays = try container.decodeIfPresent([Int].self, forKey: .weekdays) ?? []
        end = (try? container.decodeIfPresent(End.self, forKey: .end)) ?? .never
        timeZoneIdentifier = try container.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
            ?? TimeZone.current.identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(frequency.rawValue, forKey: .frequency)
        try container.encode(start, forKey: .start)
        try container.encode(interval, forKey: .interval)
        try container.encode(weekdays, forKey: .weekdays)
        try container.encode(end, forKey: .end)
        try container.encode(timeZoneIdentifier, forKey: .timeZoneIdentifier)
    }
}

/// The one place schedules are turned into and out of their stored JSON form.
public enum ScheduleCoding {
    public static func encode(_ schedule: Schedule) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(schedule) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ json: String) -> Schedule? {
        guard !json.isEmpty else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Schedule.self, from: Data(json.utf8))
    }
}
