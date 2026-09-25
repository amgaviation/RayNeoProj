import Foundation

public enum OptOutIntent: Equatable, Sendable {
    case optOut
    case optIn
}

/// Recognises replies that mean "stop messaging me" (and "start again").
///
/// US rules (TCPA, FCC 2024 revocation order) require honouring opt-outs sent
/// "by any reasonable means", so beyond the standard keywords this also catches
/// short plain-language requests. It deliberately ignores longer messages that
/// merely contain the word "stop" ("stop by at 5?").
public enum OptOutDetector {
    public static let optOutKeywords: Set<String> = [
        "STOP", "STOPALL", "STOP ALL", "UNSUBSCRIBE", "CANCEL", "END", "QUIT",
        "OPTOUT", "OPT OUT", "OPT-OUT", "REVOKE", "REMOVE", "REMOVE ME",
    ]

    public static let optInKeywords: Set<String> = [
        "START", "UNSTOP", "SUBSCRIBE", "RESUME", "OPTIN", "OPT IN", "OPT-IN",
    ]

    /// Phrases that signal an opt-out anywhere in a short message.
    public static let optOutPhrases: [String] = [
        "STOP TEXTING", "STOP MESSAGING", "STOP SENDING", "STOP CONTACTING",
        "DONT TEXT", "DO NOT TEXT", "DONT MESSAGE", "DO NOT MESSAGE",
        "UNSUBSCRIBE", "OPT ME OUT", "TAKE ME OFF", "REMOVE ME FROM", "NO MORE MESSAGES", "NO MORE TEXTS",
    ]

    /// Politeness words allowed after a keyword ("stop please", "STOP now").
    private static let trailingFillers: Set<String> = ["PLEASE", "PLS", "NOW", "THANKS", "THANK YOU", "THX", "IT"]

    public static func classify(_ text: String) -> OptOutIntent? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }

        if optOutKeywords.contains(normalized) { return .optOut }
        if optInKeywords.contains(normalized) { return .optIn }

        // Keyword followed only by a politeness word.
        for keyword in optOutKeywords where normalized.hasPrefix(keyword + " ") {
            let rest = String(normalized.dropFirst(keyword.count + 1))
            if trailingFillers.contains(rest) { return .optOut }
        }
        for keyword in optInKeywords where normalized.hasPrefix(keyword + " ") {
            let rest = String(normalized.dropFirst(keyword.count + 1))
            if trailingFillers.contains(rest) { return .optIn }
        }

        if normalized.count <= 80 {
            for phrase in optOutPhrases where normalized.contains(phrase) {
                return .optOut
            }
        }
        return nil
    }

    /// Uppercase, apostrophes removed, punctuation turned into spaces, spaces collapsed.
    static func normalize(_ text: String) -> String {
        var cleaned = ""
        for scalar in text.uppercased().unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" || scalar == "\u{2018}" {
                continue
            }
            if scalar == "-" {
                cleaned.unicodeScalars.append(scalar)
            } else if CharacterSet.alphanumerics.contains(scalar) {
                cleaned.unicodeScalars.append(scalar)
            } else {
                cleaned.append(" ")
            }
        }
        return cleaned
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
