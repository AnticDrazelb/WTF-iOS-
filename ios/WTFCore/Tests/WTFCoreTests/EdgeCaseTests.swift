import XCTest
@testable import WTFCore

/// Cases found in review: dotted times, late nights, clock changes and questions misread.
final class EdgeCaseTests: XCTestCase {
    // Sunday 11 October 2026, 15:12
    let ref = DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 12)
    func p(_ s: String) -> WhenResult? { WhenParser.parse(s, reference: ref) }
    func d(_ r: WhenResult?) -> [Int] { r.map { [$0.year, $0.month, $0.day] } ?? [] }
    func t(_ r: WhenResult?) -> [Int]? { r?.hour.map { [$0, r!.minute!] } }
    var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        london.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: m, second: s))!
    }

    func testDottedTimes() {
        XCTAssertEqual(t(p("dinner at 7.30pm tomorrow")), [19, 30])
        XCTAssertEqual(d(p("dinner at 7.30pm tomorrow")), [2026, 10, 12])
        XCTAssertEqual(t(p("dentist at 10.30 on friday")), [10, 30])
        XCTAssertEqual(d(p("dentist at 10.30 on friday")), [2026, 10, 16])
        // Money isn't a time.
        XCTAssertNil(t(p("it's £3.50 tomorrow")))
        // Nor is a number that can't be a time, or a dotted date.
        XCTAssertNil(t(p("page 45.30 tomorrow")))
        XCTAssertNil(t(p("tomorrow, 15.10.26")))
    }

    func testMidnightIsTheEndOfTheDayNamed() {
        XCTAssertEqual(d(p("Friday at midnight")), [2026, 10, 16])
        XCTAssertEqual(t(p("Friday at midnight")), [23, 59])
    }

    func testLeapDayWaitsForALeapYear() {
        XCTAssertEqual(d(p("29 February")), [2028, 2, 29])
    }

    func testTomorrowSaidAfterMidnightIsFromThatDay() {
        let lines = ["[23:40:00] You: Right, it's getting late.", "[00:20:00] You: I've got the dentist tomorrow at 10am."]
        let found = ActionRules.ruleActions(lines, conversationStart: date(2026, 10, 14, 23, 40), title: nil, calendar: london)
        let dentist = found.first { $0.type == .event }
        XCTAssertEqual(dentist.flatMap { $0.resolved }.map { [$0.year, $0.month, $0.day] }, [2026, 10, 16])
    }

    func testMergeKeepsADifferentPlanOnTheSameDay() {
        let tomorrow = WhenResult(year: 2026, month: 10, day: 12, hour: 10, minute: 0)
        let evening = WhenResult(year: 2026, month: 10, day: 12, hour: 19, minute: 0)
        let model = [ExtractedAction(type: .event, title: "Dentist", whenText: "tomorrow at 10am", resolved: tomorrow)]
        let rules = [ExtractedAction(type: .event, title: "Dentist appointment", whenText: "tomorrow at 10am", resolved: tomorrow),
                     ExtractedAction(type: .event, title: "Party", whenText: "tomorrow at 7pm", resolved: evening)]
        XCTAssertEqual(ActionRules.merge(model, rules).map(\.title), ["Dentist", "Party"])
    }

    func testLineTimesKeepTheWallClockWhenTheClocksGoForward() {
        // 29 March 2026: London's clocks go forward at 01:00.
        let lines: [Substring] = ["[00:30:00] Speech: Still up?", "[03:00:00] Speech: Yes."]
        let times = TranscriptFormat.times(of: lines, from: date(2026, 3, 29, 0, 30), calendar: london)
        XCTAssertEqual(times[1], date(2026, 3, 29, 3, 0))
    }

    func testRecapWhenYouHaveBeenQuietForAWhile() {
        var lines = ["[10:00:00] You: Shall we talk about the trip then?"]
        for i in 1...13 {
            lines.append(String(format: "[10:%02d:00] Speaker %d: This is turn number %d of the long chat about the trip.", i, i % 2 + 1, i))
        }
        let t = lines.joined(separator: "\n")
        let start = date(2026, 10, 12, 10, 0), now = date(2026, 10, 12, 10, 14)
        let r = QuickRecap.of(t, start: start, now: now, calendar: london)
        XCTAssertNotNil(r)
        XCTAssertTrue(r?.hasPrefix("Speaker 2 was saying") ?? false, r ?? "")
        XCTAssertTrue(QuickRecap.spoken(t, start: start, now: now, calendar: london)?.hasPrefix("Speaker 2 was saying") ?? false)
    }

    func testTheVoiceTipCanBeLeftOut() {
        let t = "[09:00:00] Speaker 1: Did you book the MOT?\n[09:00:04] Speaker 2: Yes, Thursday at nine, and they'll look at the rattle too."
        let start = date(2026, 10, 12, 9, 0), now = date(2026, 10, 12, 9, 0, 30)
        XCTAssertTrue(QuickRecap.of(t, start: start, now: now, calendar: london)!.contains("That\u{2019}s Me"))
        XCTAssertFalse(QuickRecap.of(t, start: start, now: now, calendar: london, tip: false)!.contains("That\u{2019}s Me"))
    }

    func testTimesFollowTheLocale() {
        let at = date(2026, 10, 12, 14, 5), now = date(2026, 10, 12, 16, 0)
        XCTAssertEqual(QuickRecap.ago(at, now: now, calendar: london), "at 14:05")
        var us = london
        us.locale = Locale(identifier: "en_US")
        let said = QuickRecap.ago(at, now: now, calendar: us)
        XCTAssertTrue(said.contains("2:05") && said.contains("PM"), said)
        let items = [ListAnswers.Item(type: .event, title: "Dentist", start: date(2026, 10, 15, 14, 30))]
        let answer = ListAnswers.answer("What appointments have I got?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(answer.contains("Dentist: Thu") && answer.contains("15 Oct") && answer.contains("14:30"), answer)
    }

    func testJustDoesNotMakeItAboutTheLatest() {
        XCTAssertEqual(Prompts.intent("I just can't remember, what's Tom's new address?"), .focused)
        XCTAssertEqual(Prompts.intent("Where was I with the party plans?"), .focused)
        XCTAssertEqual(Prompts.intent("What was I just on about?"), .latest)
        XCTAssertEqual(Prompts.intent("Where was I?"), .latest)
        XCTAssertEqual(Prompts.intent("What did I just say?"), .latest)
    }

    func testPickingSomeoneUpIsNotShopping() {
        let items = [ListAnswers.Item(type: .buy, title: "Milk")]
        XCTAssertNil(ListAnswers.answer("When do I pick up Ezra?", open: items))
        XCTAssertNil(ListAnswers.answer("What time do the shops shut?", open: items))
        XCTAssertEqual(ListAnswers.answer("What do I need from the shops?", open: items), "To buy:\n\u{2022} Milk")
    }
}
