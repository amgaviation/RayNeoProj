import Foundation

/// Settings that shape every rendered message.
public struct RenderSettings: Equatable, Sendable {
    /// Replaces `{sender}`.
    public var senderName: String
    public var locale: Locale
    /// Appended on its own line when non-empty, e.g. "Reply STOP to opt out."
    public var footer: String

    public init(senderName: String = "", locale: Locale = .current, footer: String = "") {
        self.senderName = senderName
        self.locale = locale
        self.footer = footer
    }
}

/// Fills `{placeholders}` in a reminder's message.
public enum TemplateRenderer {
    public struct Token: Identifiable, Equatable, Sendable {
        public let name: String
        public let summary: String
        public var id: String { name }
        public var placeholder: String { "{\(name)}" }
    }

    public static let tokens: [Token] = [
        Token(name: "first_name", summary: "Recipient's first name"),
        Token(name: "name", summary: "Recipient's full name"),
        Token(name: "last_name", summary: "Recipient's last name"),
        Token(name: "title", summary: "Reminder title"),
        Token(name: "date", summary: "Date of this reminder, e.g. Mon, Mar 9"),
        Token(name: "time", summary: "Time of this reminder, e.g. 9:00 AM"),
        Token(name: "weekday", summary: "Day of the week, e.g. Monday"),
        Token(name: "sender", summary: "Your name from Settings"),
    ]

    /// Word used when a recipient has no name, so "Hi {first_name}" reads "Hi there".
    public static let fallbackName = "there"

    public static func render(
        template: String,
        recipientName: String,
        reminderTitle: String,
        occurrence: Date,
        timeZone: TimeZone,
        settings: RenderSettings
    ) -> String {
        let values = self.values(
            recipientName: recipientName,
            reminderTitle: reminderTitle,
            occurrence: occurrence,
            timeZone: timeZone,
            settings: settings
        )
        var text = substitute(template, values: values)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let footer = settings.footer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !footer.isEmpty {
            text += text.isEmpty ? footer : "\n\n" + footer
        }
        return text
    }

    public static func values(
        recipientName: String,
        reminderTitle: String,
        occurrence: Date,
        timeZone: TimeZone,
        settings: RenderSettings
    ) -> [String: String] {
        let trimmedName = recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedName.split(whereSeparator: { $0 == " " }).map(String.init)
        let first = parts.first ?? ""
        let last = parts.dropFirst().joined(separator: " ")
        return [
            "first_name": first.isEmpty ? fallbackName : first,
            "name": trimmedName.isEmpty ? fallbackName : trimmedName,
            "last_name": last,
            "title": reminderTitle,
            "date": Schedule.format(occurrence, template: "EEEMMMd", locale: settings.locale, timeZone: timeZone),
            "time": Schedule.format(occurrence, template: "jmm", locale: settings.locale, timeZone: timeZone),
            "weekday": Schedule.format(occurrence, template: "EEEE", locale: settings.locale, timeZone: timeZone),
            "sender": settings.senderName,
        ]
    }

    /// Replaces `{token}` (case-insensitive) with its value. Unknown tokens and
    /// stray braces are left untouched.
    public static func substitute(_ template: String, values: [String: String]) -> String {
        var lookup: [String: String] = [:]
        for (key, value) in values { lookup[key.lowercased()] = value }

        var output = ""
        var index = template.startIndex
        while index < template.endIndex {
            let character = template[index]
            if character == "{",
               let close = template[index...].firstIndex(of: "}") {
                let name = template[template.index(after: index)..<close]
                if !name.isEmpty,
                   name.allSatisfy({ $0.isLetter || $0 == "_" }),
                   let value = lookup[name.lowercased()] {
                    output += value
                    index = template.index(after: close)
                    continue
                }
            }
            output.append(character)
            index = template.index(after: index)
        }
        return output
    }

    /// Placeholders in `template` that are not recognised, for editor warnings.
    public static func unknownTokens(in template: String) -> [String] {
        let known = Set(tokens.map(\.name))
        var unknown: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0 == "_" }),
                   !known.contains(name.lowercased()), !unknown.contains(name) {
                    unknown.append(name)
                }
                index = template.index(after: close)
            } else {
                index = template.index(after: index)
            }
        }
        return unknown
    }
}
