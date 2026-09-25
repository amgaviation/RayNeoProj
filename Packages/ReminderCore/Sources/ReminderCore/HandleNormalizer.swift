import Foundation

/// Turns whatever a person typed into the handle Messages uses: an E.164 phone
/// number ("+15551234567") or a lowercase email address.
public enum HandleNormalizer {
    /// Returns nil when the input cannot be a phone number or email address.
    /// - Parameter defaultCountryCode: Calling code for numbers typed without one, e.g. "1" or "44".
    public static func normalize(_ raw: String, defaultCountryCode: String = "1") -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("@") {
            return normalizeEmail(trimmed)
        }

        // Anything with letters left after removing phone punctuation is not a number.
        let allowed = Set("0123456789+-()./ \u{00A0}")
        guard trimmed.allSatisfy({ allowed.contains($0) }) else { return nil }

        let hasPlus = trimmed.hasPrefix("+")
        let digits = String(trimmed.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))
        let countryCode = String(defaultCountryCode.unicodeScalars.filter { ("0"..."9").contains($0) }.map(Character.init))

        if hasPlus {
            return (8...15).contains(digits.count) ? "+" + digits : nil
        }
        if digits.hasPrefix("00"), (10...17).contains(digits.count) {
            return "+" + String(digits.dropFirst(2))
        }
        guard !countryCode.isEmpty else {
            return (8...15).contains(digits.count) ? "+" + digits : nil
        }

        if countryCode == "1" {
            // North American Numbering Plan: 10 digits, optionally with a leading 1.
            if digits.count == 10 { return "+1" + digits }
            if digits.count == 11, digits.hasPrefix("1") { return "+" + digits }
            return nil
        }

        // Typed with the country code but without "+", e.g. "447911123456".
        if digits.hasPrefix(countryCode), digits.count >= countryCode.count + 8, digits.count <= 15 {
            return "+" + digits
        }
        var national = Substring(digits)
        while national.hasPrefix("0") { national = national.dropFirst() }  // trunk prefix
        let full = countryCode + String(national)
        return (8...15).contains(full.count) && national.count >= 6 ? "+" + full : nil
    }

    public static func normalizeEmail(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[1].contains("."),
              !parts[1].hasPrefix("."),
              !parts[1].hasSuffix("."),
              !email.contains(where: { $0.isWhitespace }) else { return nil }
        return email
    }

    public static func isEmail(_ handle: String) -> Bool {
        handle.contains("@")
    }

    /// True when two handles (normalized or not) point at the same person.
    public static func matches(_ lhs: String, _ rhs: String, defaultCountryCode: String = "1") -> Bool {
        let a = normalize(lhs, defaultCountryCode: defaultCountryCode) ?? lhs.lowercased()
        let b = normalize(rhs, defaultCountryCode: defaultCountryCode) ?? rhs.lowercased()
        return a == b
    }

    /// "+1 (555) 123-4567" for North American numbers; everything else as stored.
    public static func displayFormat(_ handle: String) -> String {
        guard handle.hasPrefix("+1"), handle.count == 12 else { return handle }
        let digits = Array(handle.dropFirst(2))
        return "+1 (\(String(digits[0..<3]))) \(String(digits[3..<6]))-\(String(digits[6..<10]))"
    }
}

/// Calling codes for the regions people most often pick. Used to default the
/// country code from the device's region.
public enum CallingCodes {
    public static let byRegion: [String: String] = [
        "US": "1", "CA": "1", "PR": "1", "GB": "44", "IE": "353", "AU": "61", "NZ": "64",
        "DE": "49", "FR": "33", "ES": "34", "IT": "39", "NL": "31", "BE": "32", "CH": "41",
        "AT": "43", "SE": "46", "NO": "47", "DK": "45", "FI": "358", "PT": "351", "PL": "48",
        "MX": "52", "BR": "55", "AR": "54", "CO": "57", "CL": "56", "IN": "91", "JP": "81",
        "KR": "82", "CN": "86", "HK": "852", "SG": "65", "PH": "63", "ZA": "27", "AE": "971",
        "SA": "966", "IL": "972", "TR": "90",
    ]

    public static func callingCode(forRegion region: String?) -> String {
        guard let region else { return "1" }
        return byRegion[region.uppercased()] ?? "1"
    }
}
