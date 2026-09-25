import Foundation

/// Helpers for reading the Messages database (~/Library/Messages/chat.db) on the
/// relay Mac. Kept here, free of SQLite and AppKit, so they can be unit tested.
public enum AppleTime {
    /// chat.db stores dates as time since 2001-01-01 UTC: nanoseconds on current
    /// macOS, seconds on very old databases.
    public static func date(fromChatDB value: Int64) -> Date {
        let seconds = value > 1_000_000_000_000 ? Double(value) / 1_000_000_000 : Double(value)
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// Nanoseconds since 2001-01-01, the unit current chat.db rows use.
    public static func chatDBValue(from date: Date) -> Int64 {
        Int64((date.timeIntervalSinceReferenceDate * 1_000_000_000).rounded())
    }
}

/// Pulls the plain text out of `message.attributedBody`.
///
/// Recent macOS leaves `message.text` empty and stores the body as an archived
/// NSAttributedString in Apple's "typedstream" format. The string sits after an
/// `NSString` class marker as `0x2B <length> <UTF-8 bytes>`, where the length is
/// one byte, or `0x81` + 2 bytes / `0x82` + 4 bytes little-endian.
/// This never throws: unreadable input yields nil.
public enum TypedStreamText {
    private static let marker: [UInt8] = Array("NSString".utf8)

    public static func extract(from data: Data) -> String? {
        extract(from: [UInt8](data))
    }

    public static func extract(from bytes: [UInt8]) -> String? {
        guard bytes.count > marker.count else { return nil }
        var searchFrom = 0
        while let markerIndex = find(marker, in: bytes, from: searchFrom) {
            searchFrom = markerIndex + 1
            var cursor = markerIndex + marker.count

            // The 0x2B tag follows within a few bytes of the class name.
            let scanLimit = min(bytes.count, cursor + 8)
            var foundTag = false
            while cursor < scanLimit {
                if bytes[cursor] == 0x2B {
                    foundTag = true
                    cursor += 1
                    break
                }
                cursor += 1
            }
            guard foundTag, cursor < bytes.count else { continue }

            var length = 0
            let lead = bytes[cursor]
            if lead == 0x81 {
                guard cursor + 2 < bytes.count else { continue }
                length = Int(bytes[cursor + 1]) | Int(bytes[cursor + 2]) << 8
                cursor += 3
            } else if lead == 0x82 {
                guard cursor + 4 < bytes.count else { continue }
                length = Int(bytes[cursor + 1])
                    | Int(bytes[cursor + 2]) << 8
                    | Int(bytes[cursor + 3]) << 16
                    | Int(bytes[cursor + 4]) << 24
                cursor += 5
            } else if lead < 0x80 {
                length = Int(lead)
                cursor += 1
            } else {
                continue
            }

            guard length > 0, cursor + length <= bytes.count else { continue }
            if let text = String(bytes: bytes[cursor..<(cursor + length)], encoding: .utf8), !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard needle.count <= haystack.count, start <= haystack.count - needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0] {
                var matched = true
                for offset in 1..<needle.count where haystack[index + offset] != needle[offset] {
                    matched = false
                    break
                }
                if matched { return index }
            }
            index += 1
        }
        return nil
    }
}

/// Keeps the relay from sending in bursts that look like spam to Apple.
public struct SendThrottle: Equatable, Sendable {
    /// Maximum messages in any rolling 60 minutes. 0 disables the cap.
    public var hourlyCap: Int
    /// Minimum seconds between two messages.
    public var minimumSpacing: TimeInterval

    public init(hourlyCap: Int, minimumSpacing: TimeInterval) {
        self.hourlyCap = hourlyCap
        self.minimumSpacing = minimumSpacing
    }

    /// Seconds to wait before the next send, or nil when the hourly cap is reached.
    public func delayBeforeNextSend(recentSends: [Date], now: Date) -> TimeInterval? {
        let lastHour = recentSends.filter { now.timeIntervalSince($0) < 3_600 && $0 <= now }
        if hourlyCap > 0, lastHour.count >= hourlyCap {
            return nil
        }
        guard let last = recentSends.filter({ $0 <= now }).max() else { return 0 }
        let elapsed = now.timeIntervalSince(last)
        return elapsed >= minimumSpacing ? 0 : minimumSpacing - elapsed
    }
}

/// Minimal RFC 4180 CSV writer for exporting the delivery log.
public enum CSV {
    public static func escape(_ field: String) -> String {
        let needsQuotes = field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r")
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    public static func make(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\r\n") + "\r\n"
    }
}
