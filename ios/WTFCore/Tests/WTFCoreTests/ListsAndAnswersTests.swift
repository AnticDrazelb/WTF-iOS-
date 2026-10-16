import XCTest
@testable import WTFCore

/// What went wrong on a real phone (Wednesday 14 October 2026, Ezra's birthday), put right.
final class ListsAndAnswersTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }
    var start: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 14, hour: 14, minute: 4))! }
    let lines = [
        "[14:04:10] Speaker 1: Right, so we are gonna go and pick up Ezra from school.",
        "[14:04:20] Speaker 1: And then we are gonna go to McDonald's get him a happy meal.",
        "[14:04:30] Speaker 2: Um, and, yeah, we'll have some cupcakes, and, yeah, all of that kind of stuff, really.",
        "[14:05:00] Speaker 1: He will open up the rest of his birthday presents as he turned five today.",
    ]

    func testPickingSomeoneUpIsntShopping() {
        let found = ActionRules.ruleActions(lines, conversationStart: start, title: nil, calendar: cal, youOnly: false)
        XCTAssertFalse(found.contains { $0.type == .buy && $0.title.lowercased().contains("ezra") }, "\(found)")
        // Nothing today without a time is a calendar item: it's happening.
        XCTAssertFalse(found.contains { $0.type == .event }, "\(found)")
        let kids = ActionRules.ruleActions(["[09:00:00] You: Can you pick up the kids from nursery and then grab some milk?"],
                                           conversationStart: start, title: nil, calendar: cal, youOnly: false).filter { $0.type == .buy }
        XCTAssertEqual(Set(kids.map(\.title)), ["Milk"]) // (repeats are merged later)
        // Items stop where the shop starts.
        let milk = ActionRules.ruleActions(["[09:00:00] You: I need to pick up milk from Tesco."], conversationStart: start, title: nil,
                                           calendar: cal, youOnly: false).filter { $0.type == .buy }
        XCTAssertEqual(Set(milk.map(\.title)), ["Milk"])
    }

    func testTheAIsMadeUpItemsAreLeftOut() {
        let model = ActionRules.fromModel(
            buy: ["Cupcakes", "Ezra from school"], todo: ["Confirm McDonald's details"],
            events: [("Go to McDonald's", "today", "McDonald's", false), ("Pick up Ezra from school", "today", "school", false),
                     ("Birthday", "today", nil, false)],
            conversationStart: start, lines: lines, calendar: cal)
        XCTAssertEqual(model.map(\.title), ["Cupcakes"], "\(model)")
    }

    func testOnlyBookableThingsAreNotBookedYet() {
        let said = ["[10:00:00] You: Shall we pick Ezra up from his nan's on Saturday at 2?",
                    "[10:01:00] You: We should book the dentist for Friday at 3, maybe."]
        let model = ActionRules.fromModel(buy: [], todo: [],
                                          events: [("Collect Ezra from Nan's", "Saturday at 2", nil, false), ("Dentist", "Friday at 3", nil, false)],
                                          conversationStart: start, lines: said, calendar: cal)
        XCTAssertNil(model.first { $0.title.hasPrefix("Collect") }?.note, "\(model)")
        XCTAssertEqual(model.first { $0.title == "Dentist" }?.note, "Not booked yet", "\(model)")
        // A day the AI assumed, never said, isn't a plan.
        let assumed = ActionRules.fromModel(buy: [], todo: [], events: [("Dentist", "Thursday at 3", nil, true)],
                                            conversationStart: start, lines: ["[10:01:00] You: I need to see the dentist soon."], calendar: cal)
        XCTAssertTrue(assumed.isEmpty, "\(assumed)")
    }

    func testTasksMustHaveBeenSaid() {
        let said = ["[10:00:00] You: I'll ring the garage tomorrow to confirm the MOT.", "[10:01:00] You: Tom, I'll send you the link."]
        XCTAssertTrue(ActionRules.grounded("Ring the garage to confirm the MOT", in: said))
        XCTAssertTrue(ActionRules.grounded("Send Tom the link", in: said))
        XCTAssertFalse(ActionRules.grounded("Confirm McDonald's details", in: lines))
        XCTAssertTrue(ActionRules.isCollecting("Ezra", in: lines))
        XCTAssertFalse(ActionRules.isCollecting("Cupcakes", in: lines))
    }

    func testANumberTheAIAddedIsTakenOutAgain() {
        XCTAssertEqual(Corrections.unnumbered("[1] Right, so we are gonna go", number: 1), "Right, so we are gonna go")
        XCTAssertEqual(Corrections.unnumbered("1. Right", number: 1), "Right")
        XCTAssertEqual(Corrections.unnumbered("(3) Right", number: 3), "Right")
        XCTAssertEqual(Corrections.unnumbered("10:30 works for me", number: 10), "10:30 works for me")
        XCTAssertEqual(Corrections.unnumbered("5 minutes later", number: 5), "5 minutes later")
        let original = ["[14:04:10] Speaker 1: Right, so we are gonna go and pick up Ezra from skool."]
        let fixed = Corrections.apply(["[1] Right, so we are gonna go and pick up Ezra from school."], to: original)
        XCTAssertEqual(fixed, ["[14:04:10] Speaker 1: Right, so we are gonna go and pick up Ezra from school."])
        XCTAssertEqual(Corrections.repaired("[14:04:10] Speaker 1: [1] Right, so.\n[14:04:20] You: [12] And then.\n[14:04:30] You: [Laughs] Fine."),
                       "[14:04:10] Speaker 1: Right, so.\n[14:04:20] You: And then.\n[14:04:30] You: [Laughs] Fine.")
    }

    func testAnswersStartWithTheAnswer() {
        XCTAssertEqual(Prompts.tidy("Okay, so here's a summary of the conversation.\n\nToday, Ezra's birthday plans were discussed.\n\nIt is now Wednesday, 2:06pm."),
                       "Today, Ezra's birthday plans were discussed.")
        XCTAssertEqual(Prompts.tidy("Sure, here's a summary of the conversation:\n\nYou were planning Ezra's birthday."),
                       "You were planning Ezra's birthday.")
        XCTAssertEqual(Prompts.tidy("Based on the notes, you were talking about the MOT."), "You were talking about the MOT.")
        XCTAssertEqual(Prompts.tidy("You said it's now booked for Thursday."), "You said it's now booked for Thursday.")
        XCTAssertEqual(Prompts.tidy("Right after lunch you rang the garage."), "Right after lunch you rang the garage.")
        XCTAssertEqual(Prompts.tidy("**Ezra's party**\n- Cake from Tesco\n* Balloons"), "Ezra's party\n\u{2022} Cake from Tesco\n\u{2022} Balloons")
        XCTAssertEqual(Prompts.tidy("## Garage\nIt's booked for 2-3pm."), "Garage\nIt's booked for 2-3pm.")
        XCTAssertFalse(Prompts.instructions.isEmpty)
        let one = Prompts.focused(question: "Summarise this conversation", notes: [("Today 14:04", "Ezra's birthday", nil)], best: nil, now: start)
        XCTAssertFalse(one.contains("which conversation"))
    }
}

final class TranscriptOrderTests: XCTestCase {
    let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()
    func at(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
    }

    func testNewLinesGoOnTheEnd() {
        let t = "[10:00:00] You: one\n[10:01:00] You: two"
        XCTAssertEqual(TranscriptFormat.insert("[10:02:00] You: three", at: at(11, 10, 2), into: t, from: at(11, 10, 0), calendar: cal),
                       t + "\n[10:02:00] You: three")
    }

    func testARetriedRecordingGoesBackWhereItWasSaid() {
        let t = "[10:00:00] You: one\n[10:05:00] You: three"
        XCTAssertEqual(TranscriptFormat.insert("[10:02:00] You: two", at: at(11, 10, 2), into: t, from: at(11, 10, 0), calendar: cal),
                       "[10:00:00] You: one\n[10:02:00] You: two\n[10:05:00] You: three")
    }

    func testPastMidnight() {
        let t = "[23:58:00] You: late\n[00:03:00] You: later"
        let times = TranscriptFormat.times(of: t.split(separator: "\n"), from: at(11, 23, 58), calendar: cal)
        XCTAssertEqual(times, [at(11, 23, 58), at(12, 0, 3)])
        XCTAssertEqual(TranscriptFormat.insert("[00:01:00] You: middle", at: at(12, 0, 1), into: t, from: at(11, 23, 58), calendar: cal),
                       "[23:58:00] You: late\n[00:01:00] You: middle\n[00:03:00] You: later")
    }

    func testCompactKeepsGapMarkers() {
        let t = "[10:00:00] You: one\n(\u{2026})\n[10:30:00] You: two"
        XCTAssertEqual(TranscriptFormat.compact(t), "You: one\n(\u{2026})\nYou: two")
        let plain = "[10:00:00] Speech: one\n(\u{2026})\n[10:30:00] Speech: two"
        XCTAssertEqual(TranscriptFormat.compact(plain), "one\n(\u{2026})\ntwo")
    }
}

final class FocusedBudgetTests: XCTestCase {
    func testAGeneralQuestionStaysWithinItsBudget() {
        let summary = Array(repeating: "\u{2022} A long point about what was said, who said it and what was decided about it.", count: 8).joined(separator: "\n")
        let notes = (0..<12).map { (label: "Today \(10 + $0):00", title: Optional("Conversation \($0)"), summary: Optional(summary)) }
        let transcript = (0..<300).map { "[10:\(String(format: "%02d", $0 % 60)):00] You: and then we talked about the garage and the dentist again" }.joined(separator: "\n")
        let background = "Things I know from other days:\n" + (0..<5).map { "- Fact number \($0) about someone's birthday and where they live" }.joined(separator: "\n") + "\n\n"
        for budget in [2_800, 1_800] {
            let prompt = Prompts.focused(question: "What did we decide about the garage?", notes: notes, best: ("Today 10:00", transcript),
                                         now: Date(), background: background, budget: budget)
            XCTAssertLessThanOrEqual(Prompts.tokens(prompt), budget + 20, "budget \(budget)")
            XCTAssertTrue(prompt.contains("From the transcript of Today 10:00"))
            XCTAssertTrue(prompt.contains("- Today 10:00: Conversation 0"))
            XCTAssertTrue(prompt.hasSuffix("My question: What did we decide about the garage?"))
        }
    }

    func testAFollowUpCarriesTheLastAnswerWithinTheBudget() {
        let summary = Array(repeating: "\u{2022} A long point about what was said, who said it and what was decided about it.", count: 8).joined(separator: "\n")
        let notes = (0..<12).map { (label: "Today \(10 + $0):00", title: Optional("Conversation \($0)"), summary: Optional(summary)) }
        let transcript = (0..<300).map { "[10:\(String(format: "%02d", $0 % 60)):00] You: and then we talked about the garage and the dentist again" }.joined(separator: "\n")
        let earlier = "Earlier I asked: What did we decide about the garage?\nYou answered: " + String(repeating: "You'll take the car in on Thursday. ", count: 40)
        for budget in [2_800, 1_800] {
            let prompt = Prompts.focused(question: "And what did she say?", notes: notes, best: ("Today 10:00", transcript),
                                         now: Date(), earlier: earlier, budget: budget)
            XCTAssertLessThanOrEqual(Prompts.tokens(prompt), budget + 20, "budget \(budget)")
            XCTAssertTrue(prompt.contains("Earlier I asked: What did we decide about the garage?"))
            XCTAssertTrue(prompt.hasSuffix("My question: And what did she say?"))
        }
        let plain = Prompts.focused(question: "Q?", notes: [("Today 10:00", "Garage", nil)], best: nil, now: Date())
        XCTAssertFalse(plain.contains("Earlier I asked"))
    }
}

final class AboutTodayTests: XCTestCase {
    func testOnlyTodayIsTodaysRecap() {
        XCTAssertTrue(Prompts.isAboutToday("Summarise my day so far"))
        XCTAssertTrue(Prompts.isAboutToday("What did I do today?"))
        XCTAssertFalse(Prompts.isAboutToday("Summarise yesterday"))
        XCTAssertFalse(Prompts.isAboutToday("Recap Friday's meeting"))
        XCTAssertFalse(Prompts.isAboutToday("Tell me everything about Mum's birthday"))
        XCTAssertFalse(Prompts.isAboutToday("Summarise what Sarah said so far"))
    }
}
