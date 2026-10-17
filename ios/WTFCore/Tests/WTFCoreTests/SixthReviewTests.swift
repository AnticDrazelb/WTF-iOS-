import XCTest
@testable import WTFCore

/// Cases found in the sixth review: evening plans given morning times, "next week" taken as a
/// Monday, old talk called "just", and list questions about a day or "what have I got on".
final class SixthReviewTests: XCTestCase {
    // Friday 16 October 2026, 15:12
    let ref = DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 12)
    func p(_ s: String, about: String = "") -> WhenResult? { WhenParser.parse(s, reference: ref, about: about) }
    func t(_ r: WhenResult?) -> [Int]? { r?.hour.map { [$0, r!.minute!] } }
    var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    var friday: Date { london.date(from: ref)! }
    func found(_ said: String) -> [ExtractedAction] {
        ActionRules.ruleActions(["[15:12:00] Speaker 1: " + said], conversationStart: friday, title: nil, calendar: london, youOnly: false)
    }

    func testEveningPlansAreInTheEvening() {
        XCTAssertEqual(t(p("Dinner at 8 on Saturday.")), [20, 0])
        XCTAssertEqual(t(p("The party's on Saturday at 9.")), [21, 0])
        XCTAssertEqual(t(p("Drinks on Friday at 8.")), [20, 0])
        XCTAssertEqual(t(p("Shall we do dinner Saturday at half eight?")), [20, 30])
        XCTAssertEqual(t(p("Drinks at half nine on Saturday")), [21, 30])
        XCTAssertEqual(t(p("Party at 10 on Saturday")), [22, 0])
        XCTAssertEqual(t(p("Dinner tomorrow at 9")), [21, 0])
        XCTAssertEqual(t(p("Dinner at 12 on Saturday")), [12, 0])
        // Said otherwise, or not an evening plan.
        XCTAssertEqual(t(p("Dinner on Saturday at 8 am")), [8, 0])
        XCTAssertEqual(t(p("Drinks on Saturday morning at 10")), [10, 0])
        XCTAssertEqual(t(p("The kids party is on Saturday at 10")), [10, 0])
        XCTAssertEqual(t(p("The children’s party is on Saturday at 10")), [10, 0])
        XCTAssertEqual(t(p("Dentist on Saturday at 9")), [9, 0])
        // The AI gives the when on its own: what it is goes along.
        XCTAssertEqual(t(p("Saturday at 8", about: "Dinner")), [20, 0])
        XCTAssertEqual(t(p("Saturday at 8", about: "Dentist")), [8, 0])
        let ai = ActionRules.fromModel(buy: [], todo: [], events: [(what: "Dinner", when: "Saturday at 8", place: nil, booked: false)],
                                       conversationStart: friday, calendar: london)
        XCTAssertEqual(ai.first?.resolved?.hour, 20)
        XCTAssertEqual(found("Dinner at 8 on Saturday.").first { $0.type == .event }?.resolved?.hour, 20)
    }

    func testNextWeekWithNoDayIsFlagged() {
        let r = p("We've got a meeting with the bank next week.")
        XCTAssertEqual([r?.month, r?.day], [10, 19])
        XCTAssertEqual(r?.doubt, "No day said, just next week")
        XCTAssertNotNil(p("The interview is next week sometime.")?.doubt)
        // A day said is no guess.
        XCTAssertNil(p("Next week on Tuesday")?.doubt)
        XCTAssertNil(p("Next Tuesday")?.doubt)
        XCTAssertNil(p("Next weekend")?.doubt)
        let ai = ActionRules.fromModel(buy: [], todo: [], events: [(what: "Meeting with the bank", when: "next week", place: nil, booked: false)],
                                       conversationStart: friday, calendar: london)
        XCTAssertEqual(ai.first?.note, "No day said, just next week")
    }

    func testOldTalkTodayIsNotJust() {
        let now = friday, start = now.addingTimeInterval(-5 * 3600)
        let end = now.addingTimeInterval(-4.5 * 3600)
        XCTAssertTrue(Prompts.when(start, end: end, now: now).contains("ago"))
        XCTAssertTrue(Prompts.when(start, end: end, now: now).contains("rather than \"just\""))
        XCTAssertTrue(Prompts.latest(question: "Where was I?", transcript: "", topic: nil, now: now, start: start, end: end).contains("ago"))
        XCTAssertTrue(Prompts.spoken(transcript: "", topic: nil, leftAt: nil, now: now, start: start, end: end).contains("ago"))
        // Only just now: nothing to add.
        XCTAssertEqual(Prompts.when(now.addingTimeInterval(-900), end: now.addingTimeInterval(-60), now: now), "")
        XCTAssertEqual(Prompts.when(start, now: now), "")
    }

    func testGotOnTodayIsTheList() {
        let now = friday
        let items = [ListAnswers.Item(type: .event, title: "Dentist", start: now.addingTimeInterval(3600))]
        for q in ["What have I got on today?", "Have we got anything on tomorrow?", "Got anything on this week?"] {
            XCTAssertNotNil(ListAnswers.answer(q, open: items, now: now, calendar: london), q)
        }
        XCTAssertTrue(ListAnswers.answer("What have I got on today?", open: items, now: now, calendar: london)?.contains("Dentist") ?? false)
        XCTAssertNil(ListAnswers.answer("Is there anything on the telly?", open: items, now: now, calendar: london))
        // Ask's own suggestion goes on to today's conversations (see AppModel.ask), not the list alone.
        XCTAssertNil(ListAnswers.answer("What did I say I'd do today?", open: items, now: now, calendar: london))
        XCTAssertEqual(Prompts.intent("What did I say I'd do today?"), .commitments)
    }

    func testListAnswersKeepToTheDayAsked() {
        let now = friday
        let sunday = now.addingTimeInterval(2 * 86_400), later = now.addingTimeInterval(21 * 86_400)
        let items = [ListAnswers.Item(type: .event, title: "Dentist", start: sunday),
                     ListAnswers.Item(type: .event, title: "MOT", start: later)]
        XCTAssertEqual(ListAnswers.answer("Any appointments on Friday?", open: items, now: now, calendar: london),
                       "No appointments on Friday on your list.")
        let sun = ListAnswers.answer("Any appointments on Sunday?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(sun.contains("Dentist") && !sun.contains("MOT"), sun)
        let week = ListAnswers.answer("Any appointments this weekend?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(week.contains("Dentist") && !week.contains("MOT"), week)
        let all = ListAnswers.answer("Any appointments coming up?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(all.contains("Dentist") && all.contains("MOT"), all)
    }
}
