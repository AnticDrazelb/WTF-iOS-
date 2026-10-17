import XCTest
@testable import WTFCore

/// Cases found in the fourth review: past plans read as future ones, talk read as to-dos and
/// shopping, dates and times said the British way, and questions sent to the wrong answer.
final class FourthReviewTests: XCTestCase {
    // Friday 16 October 2026, 15:12
    let ref = DateComponents(year: 2026, month: 10, day: 16, hour: 15, minute: 12)
    func p(_ s: String) -> WhenResult? { WhenParser.parse(s, reference: ref) }
    func d(_ r: WhenResult?) -> [Int] { r.map { [$0.year, $0.month, $0.day] } ?? [] }
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

    func testPastPlansAreNotSuggested() {
        for said in ["The meeting on Monday went well.", "We had dinner at the Crown on Saturday.", "Last Friday's meeting was a disaster.",
                     "Her birthday was on the 3rd.", "I went to a party on Saturday night."] {
            XCTAssertTrue(found(said).filter { $0.type == .event }.isEmpty, said)
        }
        XCTAssertNil(p("last Friday"))
        // Still to come.
        XCTAssertEqual(found("The meeting is on Monday.").first { $0.type == .event }?.title, "Meeting")
        XCTAssertEqual(found("The meeting was moved to Thursday.").first { $0.type == .event }?.title, "Meeting")
        XCTAssertEqual(found("Her birthday party's going to be on Saturday.").first { $0.type == .event }?.title, "Birthday")
    }

    func testTheAIsPastPlansAreNotSuggested() {
        let lines = ["[15:12:00] Speaker 1: We had dinner at the Crown on Saturday."]
        XCTAssertTrue(ActionRules.fromModel(buy: [], todo: [], events: [(what: "Dinner", when: "Saturday", place: "the Crown", booked: true)],
                                            conversationStart: friday, lines: lines, calendar: london).isEmpty)
        let coming = ["[15:12:00] Speaker 1: We're having dinner at the Crown on Saturday."]
        XCTAssertEqual(ActionRules.fromModel(buy: [], todo: [], events: [(what: "Dinner", when: "Saturday", place: "the Crown", booked: true)],
                                             conversationStart: friday, lines: coming, calendar: london).count, 1)
        XCTAssertEqual(found("I had to move the dentist to Monday.").first { $0.type == .event }?.title, "Dentist")
    }

    func testTalkIsNotAToDoOrShopping() {
        for said in ["I have to go now.", "I'm going to head off.", "I'll talk to you later.", "I'll catch you later.", "I'm going to go to bed.",
                     "I'll have the chicken.", "I'll wait for you.", "I'll come with you.", "I'll show you.", "I'll have to think about it.",
                     "Let's get the bill.", "I need some fresh air.", "We should get a taxi.", "Grab a seat.", "Let's grab lunch.",
                     "Pick up the pace.", "I need some advice.", "Can I get a hug?", "We need some space.", "I'll get the next round.",
                     "Grab your coat."] {
            XCTAssertEqual(found(said).map(\.title), [], said)
        }
        // Still things to do and to buy.
        XCTAssertEqual(found("I'll have to ring the garage.").map(\.title), ["Ring the garage"])
        XCTAssertEqual(found("I'll go to the bank tomorrow.").map(\.title), ["Go to the bank tomorrow"])
        XCTAssertEqual(found("I'll send you the link.").map(\.title), ["Send you the link"])
        XCTAssertEqual(found("We need some milk.").map(\.title), ["Milk"])
        XCTAssertEqual(found("Grab the bread.").map(\.title), ["Bread"])
        // The AI's shopping isn't someone being collected: "pick up drinks", "grab my prescription".
        let lines = ["[15:12:00] Speaker 1: Can you pick up drinks and grab my prescription?"]
        XCTAssertEqual(ActionRules.fromModel(buy: ["drinks", "my prescription"], todo: [], events: [], conversationStart: friday,
                                             lines: lines, calendar: london).map(\.title), ["Drinks", "My prescription"])
    }

    func testMonthAndWeekdayWithTheDayNumber() {
        XCTAssertEqual(d(p("December the 3rd")), [2026, 12, 3])
        XCTAssertEqual(d(p("on December the 3rd at 2")), [2026, 12, 3])
        XCTAssertEqual(t(p("on December the 3rd at 2")), [14, 0])
        XCTAssertEqual(d(p("March the 1st")), [2027, 3, 1])
        XCTAssertEqual(d(p("Saturday 14th")), [2026, 11, 14])
        XCTAssertNil(p("Saturday 14th")?.doubt)
        XCTAssertEqual(d(p("Tuesday 14th")), [2026, 11, 14])
        XCTAssertNotNil(p("Tuesday 14th")?.doubt)
        // A time after a weekday is still a time.
        XCTAssertEqual(d(p("Saturday 8pm")), [2026, 10, 17])
        XCTAssertEqual(t(p("Saturday 8pm")), [20, 0])
    }

    func testBritishWaysOfSayingWhen() {
        XCTAssertEqual(d(p("at 12 tonight")), [2026, 10, 16])
        XCTAssertEqual(t(p("at 12 tonight")), [23, 59])
        XCTAssertEqual(t(p("12 tonight")), [23, 59])
        XCTAssertEqual(t(p("11 tonight")), [23, 0])
        XCTAssertEqual(t(p("eight this evening")), [20, 0])
        XCTAssertNil(t(p("the one tonight")))
        XCTAssertEqual(d(p("Tuesday week")), [2026, 10, 27])
        XCTAssertEqual(d(p("a week on Tuesday")), [2026, 10, 27])
        XCTAssertEqual(d(p("a week today")), [2026, 10, 23])
        XCTAssertEqual(d(p("next weekend")), [2026, 10, 24])
        XCTAssertEqual(d(p("this weekend")), [2026, 10, 17])
        // Still as before.
        XCTAssertEqual(t(p("tomorrow at 12")), [12, 0])
        XCTAssertEqual(d(p("Tuesday")), [2026, 10, 20])
    }

    func testCurlyApostrophesAskTheSameQuestion() {
        let now = london.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 9))!
        let items = [ListAnswers.Item(type: .event, title: "Dentist", start: london.date(from: DateComponents(year: 2026, month: 10, day: 17, hour: 14)))]
        let answer = ListAnswers.answer("What\u{2019}s on tomorrow?", open: items, now: now, calendar: london)
        XCTAssertEqual(answer, ListAnswers.answer("What's on tomorrow?", open: items, now: now, calendar: london))
        XCTAssertTrue(answer?.contains("Dentist") ?? false, answer ?? "")
        XCTAssertEqual(Prompts.intent("What have I said I\u{2019}d do?"), .commitments)
    }

    func testOneThingFromTodayIsNotTheDayRecap() {
        XCTAssertFalse(Prompts.isAboutToday("Summarise today's meeting with Tom"))
        XCTAssertFalse(Prompts.isAboutToday("Recap what Sarah said today"))
        XCTAssertFalse(Prompts.isAboutToday("Tell me everything about the trip today"))
        XCTAssertTrue(Prompts.isAboutToday("Summarise my day so far"))
        XCTAssertTrue(Prompts.isAboutToday("What happened today?"))
        XCTAssertTrue(Prompts.isAboutToday("How's my day looking?"))
        XCTAssertTrue(Prompts.isAboutToday("Run me through today"))
        XCTAssertTrue(Prompts.isAboutToday("Give me a quick recap of today\u{2019}s conversations"))
        XCTAssertTrue(Prompts.isAboutToday("Summarise today for me"))
        XCTAssertTrue(Prompts.isAboutToday("Recap everything I've talked about today"))
    }

    func testANamedConversationIsNotJustTheLatest() {
        XCTAssertEqual(Prompts.intent("What was that conversation with Tom about?"), .focused)
        XCTAssertEqual(Prompts.intent("What did Sarah say in the last conversation about the trip?"), .focused)
        XCTAssertEqual(Prompts.intent("What was that conversation about?"), .latest)
        XCTAssertEqual(Prompts.intent("What was I just saying about the boiler?"), .latest)
        XCTAssertEqual(Prompts.intent("I lost my train of thought"), .latest)
        XCTAssertEqual(Prompts.intent("What are we talking about right now?"), .latest)
        XCTAssertEqual(Prompts.intent("What\u{2019}s happening right now?"), .latest)
        XCTAssertEqual(Prompts.intent("Sorry, I got interrupted"), .latest)
    }

    func testTypingWTFAsksAboutTheLatest() {
        XCTAssertEqual(Prompts.intent("WTF?"), .latest)
        XCTAssertEqual(Prompts.intent("wtf was that"), .latest)
        XCTAssertEqual(Prompts.keywords("WTF?"), [])
    }

    func testTheLatestPromptDoesNotPromiseTimes() {
        let prompt = Prompts.latest(question: "What was I just on about?", transcript: "[10:00:00] You: The boiler's making that noise again",
                                    topic: nil, now: Date())
        XCTAssertFalse(prompt.contains("the time it was said"))
    }
}
