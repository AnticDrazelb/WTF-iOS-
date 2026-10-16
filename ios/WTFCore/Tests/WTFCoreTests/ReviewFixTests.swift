import XCTest
@testable import WTFCore

/// Cases found in the second review: glued am/pm, "ten to four", counts read as dates, chatter
/// read as to-dos, and questions sent to the wrong answer.
final class ReviewFixTests: XCTestCase {
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
    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ m: Int) -> Date {
        london.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: m))!
    }

    func testAmAndPmStuckToTheNumber() {
        XCTAssertEqual(t(p("Saturday 8pm")), [20, 0])
        XCTAssertEqual(t(p("tomorrow 10pm")), [22, 0])
        XCTAssertEqual(t(p("Saturday 8:30pm")), [20, 30])
        XCTAssertEqual(t(p("Saturday 8.30pm")), [20, 30])
        XCTAssertEqual(t(p("tomorrow 6am")), [6, 0])
        XCTAssertEqual(t(p("tomorrow 11am")), [11, 0])
        XCTAssertEqual(t(p("tomorrow 12am")), [0, 0])
        XCTAssertEqual(t(p("tomorrow 12pm")), [12, 0])
        XCTAssertEqual(t(p("6am flight tomorrow evening")), [6, 0])
        // Said at 15:12: "9am" is the morning, not bumped to 9pm.
        XCTAssertEqual(t(p("today at 9am")), [9, 0])
        XCTAssertEqual(t(p("Thursday at 9 a.m.")), [9, 0])
    }

    func testMinutesToAndPastTheHour() {
        XCTAssertEqual(t(p("tomorrow at ten to four")), [15, 50])
        XCTAssertEqual(t(p("tomorrow at 10 to 4")), [15, 50])
        XCTAssertEqual(t(p("dentist at 20 past 3 tomorrow")), [15, 20])
        XCTAssertEqual(t(p("dentist at twenty past three tomorrow")), [15, 20])
        XCTAssertEqual(t(p("tomorrow at twenty-five to nine in the morning")), [8, 35])
        XCTAssertEqual(t(p("tomorrow at five past 9 pm")), [21, 5])
        // A range, and a length of time, aren't a time to the hour.
        XCTAssertEqual(t(p("open tomorrow from 10 to 4")), [10, 0])
        XCTAssertNil(t(p("tomorrow it takes 5 to 10 minutes")))
    }

    func testCountsAndPricesAreNotDates() {
        XCTAssertEqual(d(p("dinner on Friday for the 4 of us")), [2026, 10, 16])
        XCTAssertNil(p("dinner on Friday for the 4 of us")?.doubt)
        XCTAssertEqual(d(p("Friday, the 2 kids are coming")), [2026, 10, 16])
        XCTAssertEqual(d(p("I'll be there tomorrow at 10 may be later")), [2026, 10, 12])
        XCTAssertNil(t(p("tomorrow it cost 2.50")))
        // Still dates.
        XCTAssertEqual(d(p("the 24th")), [2026, 10, 24])
        XCTAssertEqual(d(p("24th of October")), [2026, 10, 24])
        XCTAssertEqual(d(p("10 May")), [2027, 5, 10])
    }

    func testThisFridaySaidOnAFriday() {
        let friday = DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 12)
        XCTAssertEqual(d(WhenParser.parse("drinks this Friday at 9pm", reference: friday)), [2026, 10, 16])
        XCTAssertEqual(t(WhenParser.parse("drinks this Friday at 9pm", reference: friday)), [21, 0])
        XCTAssertEqual(d(WhenParser.parse("Friday", reference: friday)), [2026, 10, 23])
        XCTAssertEqual(d(WhenParser.parse("next Friday", reference: friday)), [2026, 10, 23])
    }

    func rules(_ said: String) -> [ExtractedAction] {
        let start = date(2026, 10, 11, 15, 0)
        return ActionRules.ruleActions(["[15:02:01] You: " + said], conversationStart: start, title: nil, calendar: london)
    }

    func testTalkIsNotAToDo() {
        for said in ["I'll see you tomorrow.", "I'll let you know.", "I'm going to be sick.", "I have to say, it was good.",
                     "I'll tell you what, that was close.", "I'll be there in a minute.", "I'll get the door."] {
            XCTAssertEqual(rules(said).filter { $0.type != .event }, [], said)
        }
        XCTAssertTrue(rules("Grab the post on the way in.").filter { $0.type == .buy }.isEmpty)
        // Real tasks still count.
        XCTAssertEqual(rules("I'll ring the plumber.").map(\.title), ["Ring the plumber"])
        XCTAssertEqual(rules("Tom, I'll let you know by Friday.").filter { $0.type == .todo }.map(\.title), ["Let Tom know by Friday"])
    }

    func testOneItemFoundOnce() {
        XCTAssertEqual(rules("Don't forget to pick up the dry cleaning.").filter { $0.type == .buy }.map(\.title), ["Dry cleaning"])
        XCTAssertEqual(rules("We need to buy a birthday card.").filter { $0.type == .buy }.map(\.title), ["Birthday card"])
        XCTAssertEqual(rules("Grab the milk on the way home.").filter { $0.type == .buy }.map(\.title), ["Milk"])
        // Two appointments with the same name on different days are both kept.
        let two = ActionRules.ruleActions(["[09:00:00] You: The meeting is on Monday at 10.", "[09:01:00] You: Another meeting on Thursday at 2."],
                                          conversationStart: date(2026, 10, 11, 9, 0), title: nil, calendar: london, youOnly: false)
        XCTAssertEqual(two.filter { $0.type == .event }.map { $0.resolved?.day }, [12, 15])
    }

    func testRecentTalkIsTheLatestNotTheDay() {
        XCTAssertEqual(Prompts.intent("Summarise what we were just talking about"), .latest)
        XCTAssertEqual(Prompts.intent("Recap what I just said"), .latest)
        XCTAssertEqual(Prompts.intent("Recap the last conversation"), .latest)
        XCTAssertEqual(Prompts.intent("What did he just say?"), .latest)
        XCTAssertEqual(Prompts.intent("Summarise my day"), .digest)
        XCTAssertEqual(Prompts.intent("What did I do today?"), .digest)
        XCTAssertNotEqual(Prompts.intent("What did I do with my keys?"), .digest)
    }

    func testListQuestionsAnswerWhatWasAsked() {
        let now = date(2026, 10, 12, 9, 0)
        let items = [ListAnswers.Item(type: .buy, title: "Milk"), ListAnswers.Item(type: .todo, title: "Ring the landlord"),
                     ListAnswers.Item(type: .event, title: "Dentist", start: date(2026, 10, 12, 14, 30)),
                     ListAnswers.Item(type: .event, title: "MOT", start: date(2026, 10, 15, 9, 0))]
        XCTAssertNil(ListAnswers.answer("What should I buy Mum for her birthday?", open: items, now: now, calendar: london))
        XCTAssertNil(ListAnswers.answer("What have I promised Tom?", open: items, now: now, calendar: london))
        let all = ListAnswers.answer("What's on my list?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(all.contains("Milk") && all.contains("Ring the landlord") && all.contains("Dentist"), all)
        let today = ListAnswers.answer("What's on today?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(today.contains("Dentist") && !today.contains("MOT"), today)
        XCTAssertEqual(ListAnswers.answer("Any meetings tomorrow?", open: items, now: now, calendar: london),
                       "No appointments tomorrow on your list.")
        XCTAssertEqual(ListAnswers.answer("What have I got to buy?", open: items, now: now, calendar: london), "To buy:\n\u{2022} Milk")
        XCTAssertEqual(ListAnswers.answer("Nothing on my lists?", open: [], now: now, calendar: london), "Nothing on your lists.")
    }

    func testListAnswersSayWhatWasHeardButNotAdded() {
        let now = date(2026, 10, 12, 9, 0)
        let items = [ListAnswers.Item(type: .buy, title: "Milk"), ListAnswers.Item(type: .buy, title: "Eggs", suggested: true),
                     ListAnswers.Item(type: .event, title: "MOT", start: date(2026, 10, 15, 9, 0), suggested: true)]
        XCTAssertEqual(ListAnswers.answer("What have I got to buy?", open: items, now: now, calendar: london),
                       "To buy:\n\u{2022} Milk\n\nHeard, not added yet:\n\u{2022} Eggs")
        let events = ListAnswers.answer("Any appointments?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(events.hasPrefix("No upcoming appointments on your list.\n\nHeard, not added yet:\n\u{2022} MOT: "), events)
        let all = ListAnswers.answer("What's on my list?", open: items, now: now, calendar: london) ?? ""
        XCTAssertTrue(all.hasPrefix("To buy:\n\u{2022} Milk\n\nHeard, not added yet:\n\u{2022} Eggs\n\u{2022} MOT: "), all)
        XCTAssertEqual(ListAnswers.answer("What's on my to-do list?", open: items, now: now, calendar: london), "Nothing on your to-do list.")
    }
}
