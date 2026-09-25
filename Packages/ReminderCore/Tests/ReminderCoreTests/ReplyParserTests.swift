import XCTest
@testable import ReminderCore

final class ReplyParserTests: XCTestCase {
    func testSnoozeVariants() {
        let cases: [(String, Int)] = [
            ("snooze", 10),
            ("Snooze!", 10),
            ("SNOOZE 20", 20),
            ("snooze 20 min", 20),
            ("snooze 20m", 20),
            ("snooze 2h", 120),
            ("snooze 1 hour 30", 90),
            ("snooze an hour", 60),
            ("snooze half an hour", 30),
            ("snooze for 15 minutes", 15),
            ("later", 10),
            ("Remind me later", 10),
            ("remind me in 45 minutes", 45),
            ("remind me in 2 hours", 120),
            ("30 min", 30),
            ("30", 30),
            ("1h", 60),
            ("snooze 5000", 1_440),
        ]
        for (text, minutes) in cases {
            XCTAssertEqual(ReplyParser.parse(text), .snooze(minutes: minutes), text)
        }
    }

    func testPauseResumeAndDone() {
        for text in ["STOP", "stop please", "Pause", "unsubscribe"] {
            XCTAssertEqual(ReplyParser.parse(text), .pause, text)
        }
        for text in ["START", "resume"] {
            XCTAssertEqual(ReplyParser.parse(text), .resume, text)
        }
        for text in ["done", "Done!", "ok", "Got it", "thanks", "👍", "✅"] {
            XCTAssertEqual(ReplyParser.parse(text), .done, text)
        }
    }

    func testOrdinaryMessagesAreIgnored() {
        for text in ["See you at 5", "500", "what time is it", "", "   ", "call mom tomorrow about the trip to Denver next week please"] {
            XCTAssertNil(ReplyParser.parse(text), text)
        }
    }
}
