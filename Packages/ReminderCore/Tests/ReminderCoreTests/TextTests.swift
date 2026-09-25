import XCTest
@testable import ReminderCore

final class TemplateTests: XCTestCase {
    private let settings = RenderSettings(senderName: "Dr. Lee's Office", locale: Locale(identifier: "en_US"))
    private let occurrence = Date(timeIntervalSince1970: 1_791_900_000)  // 2026-10-13 14:00 UTC

    func testAllTokens() {
        let text = TemplateRenderer.render(
            template: "{first_name}|{last_name}|{name}|{title}|{date}|{time}|{weekday}|{sender}",
            recipientName: "Maria del Carmen",
            reminderTitle: "Checkup",
            occurrence: occurrence,
            timeZone: TimeZone(identifier: "UTC")!,
            settings: settings
        )
        XCTAssertEqual(text, "Maria|del Carmen|Maria del Carmen|Checkup|Tue, Oct 13|2:00 PM|Tuesday|Dr. Lee's Office")
    }

    func testTokensAreCaseInsensitiveAndUnknownOnesSurvive() {
        let text = TemplateRenderer.substitute("Hi {FIRST_NAME}, see {unknown} and {not a token} {", values: ["first_name": "Ana"])
        XCTAssertEqual(text, "Hi Ana, see {unknown} and {not a token} {")
    }

    func testEmptyNameFallsBack() {
        let text = TemplateRenderer.render(
            template: "Hi {first_name}!",
            recipientName: "  ",
            reminderTitle: "",
            occurrence: occurrence,
            timeZone: TimeZone(identifier: "UTC")!,
            settings: settings
        )
        XCTAssertEqual(text, "Hi there!")
    }

    func testFooterIsAppended() {
        var withFooter = settings
        withFooter.footer = "Reply STOP to opt out."
        let text = TemplateRenderer.render(
            template: "Pay rent  \n",
            recipientName: "Sam",
            reminderTitle: "Rent",
            occurrence: occurrence,
            timeZone: TimeZone(identifier: "UTC")!,
            settings: withFooter
        )
        XCTAssertEqual(text, "Pay rent\n\nReply STOP to opt out.")
    }

    func testTimeUsesPlainSpaces() {
        let text = TemplateRenderer.render(
            template: "{time}",
            recipientName: "",
            reminderTitle: "",
            occurrence: occurrence,
            timeZone: TimeZone(identifier: "UTC")!,
            settings: settings
        )
        XCTAssertFalse(text.contains("\u{202F}"))
        XCTAssertFalse(text.contains("\u{00A0}"))
    }

    func testUnknownTokens() {
        XCTAssertEqual(TemplateRenderer.unknownTokens(in: "Hi {first_name} {firstname} {Venue} {venue}"), ["firstname", "Venue", "venue"])
        XCTAssertEqual(TemplateRenderer.unknownTokens(in: "No tokens"), [])
    }
}

final class HandleNormalizerTests: XCTestCase {
    func testUSNumbers() {
        XCTAssertEqual(HandleNormalizer.normalize("(555) 123-4567"), "+15551234567")
        XCTAssertEqual(HandleNormalizer.normalize("555.123.4567"), "+15551234567")
        XCTAssertEqual(HandleNormalizer.normalize("1 555 123 4567"), "+15551234567")
        XCTAssertEqual(HandleNormalizer.normalize("+1 (555) 123-4567"), "+15551234567")
        XCTAssertNil(HandleNormalizer.normalize("123-4567"))
        XCTAssertNil(HandleNormalizer.normalize("call me"))
        XCTAssertNil(HandleNormalizer.normalize(""))
    }

    func testInternationalNumbers() {
        XCTAssertEqual(HandleNormalizer.normalize("07911 123456", defaultCountryCode: "44"), "+447911123456")
        XCTAssertEqual(HandleNormalizer.normalize("447911123456", defaultCountryCode: "44"), "+447911123456")
        XCTAssertEqual(HandleNormalizer.normalize("+44 7911 123456"), "+447911123456")
        XCTAssertEqual(HandleNormalizer.normalize("0044 7911 123456"), "+447911123456")
        XCTAssertEqual(HandleNormalizer.normalize("0412 345 678", defaultCountryCode: "61"), "+61412345678")
    }

    func testEmails() {
        XCTAssertEqual(HandleNormalizer.normalize("  Pilot@Example.COM "), "pilot@example.com")
        XCTAssertNil(HandleNormalizer.normalize("pilot@example"))
        XCTAssertNil(HandleNormalizer.normalize("@example.com"))
        XCTAssertNil(HandleNormalizer.normalize("a b@example.com"))
    }

    func testMatchesAndDisplay() {
        XCTAssertTrue(HandleNormalizer.matches("+15551234567", "(555) 123-4567"))
        XCTAssertTrue(HandleNormalizer.matches("A@B.com", "a@b.com"))
        XCTAssertFalse(HandleNormalizer.matches("+15551234567", "+15551234568"))
        XCTAssertEqual(HandleNormalizer.displayFormat("+15551234567"), "+1 (555) 123-4567")
        XCTAssertEqual(HandleNormalizer.displayFormat("+447911123456"), "+447911123456")
    }

    func testCallingCodes() {
        XCTAssertEqual(CallingCodes.callingCode(forRegion: "gb"), "44")
        XCTAssertEqual(CallingCodes.callingCode(forRegion: nil), "1")
        XCTAssertEqual(CallingCodes.callingCode(forRegion: "ZZ"), "1")
    }
}

final class OptOutDetectorTests: XCTestCase {
    func testStandardKeywords() {
        for text in ["STOP", "stop", " Stop. ", "STOP!!", "Unsubscribe", "cancel", "END", "quit", "Opt-out", "opt out", "stop please", "STOP ALL"] {
            XCTAssertEqual(OptOutDetector.classify(text), .optOut, text)
        }
    }

    func testOptIn() {
        for text in ["START", "start", "Unstop", "resume please"] {
            XCTAssertEqual(OptOutDetector.classify(text), .optIn, text)
        }
    }

    func testPlainLanguage() {
        XCTAssertEqual(OptOutDetector.classify("Please stop texting me"), .optOut)
        XCTAssertEqual(OptOutDetector.classify("don’t text me anymore"), .optOut)
        XCTAssertEqual(OptOutDetector.classify("take me off this list"), .optOut)
    }

    func testOrdinaryRepliesAreIgnored() {
        for text in ["Stop by at 5?", "Thanks!", "Can we cancel Tuesday's appointment?", "the end of the week works", "OK", "", "👍"] {
            XCTAssertNil(OptOutDetector.classify(text), text)
        }
    }
}

final class MessagesDatabaseTests: XCTestCase {
    private func blob(for text: String) -> [UInt8] {
        let body = Array(text.utf8)
        var bytes: [UInt8] = Array("\u{04}\u{0B}streamtyped".utf8) + [0x81, 0xE8, 0x03, 0x84, 0x01, 0x40, 0x84, 0x84, 0x84]
        bytes += Array("NSMutableAttributedString".utf8) + [0x00, 0x84, 0x84]
        bytes += Array("NSAttributedString".utf8) + [0x00, 0x84, 0x84]
        bytes += Array("NSObject".utf8) + [0x00, 0x85, 0x92, 0x84, 0x84, 0x84]
        bytes += Array("NSString".utf8) + [0x01, 0x94, 0x84, 0x01, 0x2B]
        if body.count < 0x80 {
            bytes.append(UInt8(body.count))
        } else {
            bytes += [0x81, UInt8(body.count & 0xFF), UInt8(body.count >> 8)]
        }
        bytes += body
        bytes += [0x86, 0x84, 0x02, 0x69, 0x49, 0x01]
        bytes += Array("NSDictionary".utf8)
        return bytes
    }

    func testExtractsShortText() {
        XCTAssertEqual(TypedStreamText.extract(from: blob(for: "STOP")), "STOP")
        XCTAssertEqual(TypedStreamText.extract(from: Data(blob(for: "Merci 👍"))), "Merci 👍")
    }

    func testExtractsLongText() {
        let long = String(repeating: "Reminder text. ", count: 40)
        XCTAssertEqual(TypedStreamText.extract(from: blob(for: long)), long)
    }

    func testGarbageYieldsNil() {
        XCTAssertNil(TypedStreamText.extract(from: []))
        XCTAssertNil(TypedStreamText.extract(from: Array("NSString".utf8)))
        XCTAssertNil(TypedStreamText.extract(from: Array("NSString".utf8) + [0x01, 0x2B, 0x7F, 0x41]))
    }

    func testAppleTimeConversions() {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let nanos = AppleTime.chatDBValue(from: date)
        XCTAssertEqual(AppleTime.date(fromChatDB: nanos).timeIntervalSince1970, 1_790_000_000, accuracy: 0.001)
        // Legacy seconds-based rows.
        let seconds = Int64(date.timeIntervalSinceReferenceDate)
        XCTAssertEqual(AppleTime.date(fromChatDB: seconds).timeIntervalSince1970, 1_790_000_000, accuracy: 1)
    }

    func testThrottle() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let throttle = SendThrottle(hourlyCap: 3, minimumSpacing: 5)
        XCTAssertEqual(throttle.delayBeforeNextSend(recentSends: [], now: now), 0)
        XCTAssertEqual(throttle.delayBeforeNextSend(recentSends: [now.addingTimeInterval(-2)], now: now)!, 3, accuracy: 0.001)
        XCTAssertEqual(throttle.delayBeforeNextSend(recentSends: [now.addingTimeInterval(-60)], now: now), 0)
        let full = [now.addingTimeInterval(-100), now.addingTimeInterval(-200), now.addingTimeInterval(-300)]
        XCTAssertNil(throttle.delayBeforeNextSend(recentSends: full, now: now))
        let old = [now.addingTimeInterval(-4_000), now.addingTimeInterval(-5_000), now.addingTimeInterval(-6_000)]
        XCTAssertEqual(throttle.delayBeforeNextSend(recentSends: old, now: now), 0)
        XCTAssertEqual(SendThrottle(hourlyCap: 0, minimumSpacing: 0).delayBeforeNextSend(recentSends: full, now: now), 0)
    }

    func testCSV() {
        let csv = CSV.make(header: ["a", "b"], rows: [["x,y", "say \"hi\""], ["line\nbreak", "plain"]])
        XCTAssertEqual(csv, "a,b\r\n\"x,y\",\"say \"\"hi\"\"\"\r\n\"line\nbreak\",plain\r\n")
    }
}
