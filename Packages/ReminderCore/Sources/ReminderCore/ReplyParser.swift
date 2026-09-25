import Foundation

/// What a reply to a reminder text asks for.
public enum ReplyCommand: Equatable, Sendable {
    /// Send the last reminder again after this many minutes.
    case snooze(minutes: Int)
    /// Stop all texts until resumed ("STOP", "PAUSE", …).
    case pause
    /// Turn texts back on ("START", "RESUME", …).
    case resume
    /// Acknowledged ("DONE", "OK"). Nothing to do but it is logged.
    case done
}

/// Reads replies to reminder texts. The relay only acts on replies from the
/// person the reminders go to, and only on short messages that clearly match.
public enum ReplyParser {
    public static let defaultSnoozeMinutes = 10
    public static let maxSnoozeMinutes = 24 * 60

    private static let pauseWords: Set<String> = ["PAUSE", "MUTE"]
    private static let doneWords: Set<String> = [
        "DONE", "DID IT", "COMPLETED", "COMPLETE", "FINISHED", "OK", "OKAY", "K", "GOT IT", "THANKS", "THANK YOU", "TY",
    ]
    private static let doneSymbols: Set<String> = ["👍", "✅", "✔️", "👌"]

    public static func parse(_ text: String) -> ReplyCommand? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return nil }
        if doneSymbols.contains(trimmed) { return .done }

        let normalized = OptOutDetector.normalize(trimmed)
        guard !normalized.isEmpty else { return nil }

        if let minutes = snoozeMinutes(normalized) { return .snooze(minutes: minutes) }
        if pauseWords.contains(normalized) { return .pause }
        switch OptOutDetector.classify(trimmed) {
        case .optOut: return .pause
        case .optIn: return .resume
        case nil: break
        }
        if doneWords.contains(normalized) { return .done }
        return nil
    }

    /// Minutes asked for by "SNOOZE", "SNOOZE 20", "LATER", "REMIND ME IN 2 HOURS",
    /// or a bare duration such as "30 MIN". Nil when the text isn't a snooze.
    static func snoozeMinutes(_ normalized: String) -> Int? {
        var words = normalized.split(separator: " ").map(String.init)
        guard let first = words.first else { return nil }

        let isCommand: Bool
        if first == "SNOOZE" || first == "LATER" {
            words.removeFirst()
            isCommand = true
        } else if words.starts(with: ["REMIND", "ME"]) {
            words.removeFirst(2)
            if words.first == "LATER" { words.removeFirst() }
            isCommand = true
        } else {
            isCommand = false
        }
        if words.first == "IN" || words.first == "FOR" { words.removeFirst() }

        if words.isEmpty {
            return isCommand ? defaultSnoozeMinutes : nil
        }
        guard let minutes = duration(words) else {
            // "SNOOZE PLEASE" still snoozes; a stray number without a command does not.
            return isCommand ? defaultSnoozeMinutes : nil
        }
        if !isCommand, words.count == 1, Int(words[0]) != nil {
            // A bare number counts as minutes only when it is small and plausible.
            guard minutes <= 240 else { return nil }
        }
        return min(max(minutes, 1), maxSnoozeMinutes)
    }

    /// "20", "20 MIN", "20M", "2 H", "2HRS", "AN HOUR", "HALF AN HOUR", "1 HOUR 30".
    static func duration(_ words: [String]) -> Int? {
        let text = words.joined(separator: " ")
        switch text {
        case "AN HOUR", "A HOUR", "1 HOUR", "ONE HOUR": return 60
        case "HALF AN HOUR", "HALF HOUR", "HALF HR": return 30
        case "A MINUTE", "A MIN": return 1
        case "A FEW MINUTES", "A FEW MIN", "FEW MINUTES", "A BIT", "A WHILE": return defaultSnoozeMinutes
        default: break
        }

        var total = 0
        var pendingNumber: Int?
        var sawAny = false
        for word in words {
            if let number = Int(word) {
                if let pending = pendingNumber { total += pending }  // "90" then "30": treat as minutes
                pendingNumber = number
                sawAny = true
                continue
            }
            if let (number, unit) = splitNumberAndUnit(word) {
                total += number * unit
                sawAny = true
                continue
            }
            if let unit = unitMinutes(word) {
                guard let number = pendingNumber else { return nil }
                total += number * unit
                pendingNumber = nil
                continue
            }
            return nil
        }
        if let pending = pendingNumber { total += pending }
        return sawAny && total > 0 ? total : nil
    }

    private static func unitMinutes(_ word: String) -> Int? {
        switch word {
        case "M", "MIN", "MINS", "MINUTE", "MINUTES": return 1
        case "H", "HR", "HRS", "HOUR", "HOURS": return 60
        default: return nil
        }
    }

    /// "20M" → (20, 1), "2HRS" → (2, 60).
    private static func splitNumberAndUnit(_ word: String) -> (Int, Int)? {
        let digits = word.prefix { $0.isNumber }
        guard !digits.isEmpty, let number = Int(digits) else { return nil }
        guard let unit = unitMinutes(String(word.dropFirst(digits.count))) else { return nil }
        return (number, unit)
    }
}
