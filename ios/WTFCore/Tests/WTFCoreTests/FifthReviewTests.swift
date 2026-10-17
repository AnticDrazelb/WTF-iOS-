import XCTest
@testable import WTFCore

/// Cases found in the fifth review: times lost to the word after them, everyday talk read as
/// to-dos and shopping, and questions about one thing sent to the latest talk or the list.
final class FifthReviewTests: XCTestCase {
    // Friday 16 October 2026, 15:12
    let ref = DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 12)
    func p(_ s: String) -> WhenResult? { WhenParser.parse(s, reference: ref) }
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

    func testTimesBeforeOtherWords() {
        XCTAssertEqual(t(p("Dentist's on Tuesday at 3 then we can get lunch.")), [15, 0])
        XCTAssertEqual(t(p("Can we do the meeting at 3 Thursday?")), [15, 0])
        XCTAssertNotNil(t(p("The party's Saturday at 8 though.")))
        XCTAssertEqual(t(p("Doctor's appointment at 10 the day after tomorrow.")), [10, 0])
        XCTAssertEqual(t(p("The meeting is Friday at seven thirty.")), [19, 30])
        XCTAssertEqual(t(p("Monday at nine fifteen in the morning")), [9, 15])
        XCTAssertEqual(found("Dentist's on Tuesday at 3 then we can get lunch.").first { $0.type == .event }?.resolved?.hour, 15)
        // Still not times.
        XCTAssertNil(t(p("Saturday, a table for 6 people")))
        XCTAssertNil(t(p("Monday, back in 5 minutes")))
        XCTAssertNil(t(p("Tomorrow, for one thing, I'm not driving.")))
        XCTAssertNil(t(p("At one stage on Friday it rained.")))
        XCTAssertNil(t(p("Saturday for three nights")))
    }

    func testEverydayTalkIsNotAToDoOrShopping() {
        for said in ["I'll put the kettle on.", "I'll have a cup of tea.", "I'm going to sit down.", "I'm going to lose my mind.",
                     "I need to go to the toilet.", "I'll check.", "I'm going to the shop.", "I need a minute.", "I need a second.",
                     "I need a holiday.", "I need a plan.", "I need a nap.", "Let me get the kettle on.", "I ran out of patience.",
                     "I need the loo."] {
            XCTAssertEqual(found(said).filter { $0.type != .event }.map(\.title), [], said)
        }
        // Still things to do and to buy.
        XCTAssertEqual(found("We need batteries for the remote.").map(\.title), ["Batteries"])
        XCTAssertEqual(found("We need a new kettle.").map(\.title), ["Kettle"])
        XCTAssertEqual(found("We've run out of toilet roll.").map(\.title), ["Toilet roll"])
        XCTAssertEqual(found("Can you grab some shower gel?").map(\.title), ["Shower gel"])
        XCTAssertEqual(found("I'll ring the dentist.").map(\.title), ["Ring the dentist"])
        XCTAssertEqual(found("I need to sort the car insurance.").map(\.title), ["Sort the car insurance"])
    }

    func testNamedQuestionsAreNotTheLatest() {
        for q in ["What was I talking about with Tom?", "What was Tom on about?", "What was I saying about the dentist?",
                  "What were we talking about at the bank?"] {
            XCTAssertEqual(Prompts.intent(q), .focused, q)
        }
        for q in ["What was I on about?", "What were we talking about?", "What the hell was I on about?", "What was I saying?",
                  "What was I just saying about the boiler?", "Where was I?"] {
            XCTAssertEqual(Prompts.intent(q), .latest, q)
        }
    }

    func testTodayQuestionsGetTheDaysRecap() {
        for q in ["What happened today?", "What did I talk about today?", "What have I discussed today?", "Summarise my day so far"] {
            XCTAssertTrue(Prompts.isAboutToday(q), q)
            XCTAssertEqual(Prompts.intent(q), .digest, q)
        }
        XCTAssertEqual(Prompts.intent("What did Tom say about the boiler today?"), .focused)
    }

    func testQuestionsAboutOnePlanAreNotTheList() {
        let now = friday
        let items = [ListAnswers.Item(type: .event, title: "Dentist", start: now.addingTimeInterval(86_400))]
        for q in ["What's the meeting with the bank about?", "Is the restaurant booked?", "What are Sarah's plans for Christmas?"] {
            XCTAssertNil(ListAnswers.answer(q, open: items, now: now, calendar: london), q)
        }
        for q in ["What's on tomorrow?", "Any meetings this week?", "Do I have any appointments?", "What's in my diary?",
                  "Have I got anything booked?"] {
            XCTAssertNotNil(ListAnswers.answer(q, open: items, now: now, calendar: london), q)
        }
    }
}
