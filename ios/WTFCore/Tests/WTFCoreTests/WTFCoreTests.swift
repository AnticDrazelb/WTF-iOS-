import XCTest
@testable import WTFCore

/// The Android app's tests for the same logic, so both apps agree.
final class WhenParserTests: XCTestCase {
    // Sunday 11 October 2026, 15:12
    let ref = DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 12)
    func p(_ s: String) -> WhenResult? { WhenParser.parse(s, reference: ref) }
    func d(_ r: WhenResult?) -> [Int] { r.map { [$0.year, $0.month, $0.day] } ?? [] }
    func t(_ r: WhenResult?) -> [Int]? { r?.hour.map { [$0, r!.minute!] } }

    func testRelativeDays() {
        XCTAssertEqual(d(p("tomorrow")), [2026, 10, 12])
        XCTAssertEqual(d(p("the day after tomorrow")), [2026, 10, 13])
        XCTAssertEqual(d(p("tonight")), [2026, 10, 11])
        XCTAssertEqual(d(p("Thursday")), [2026, 10, 15])
        XCTAssertEqual(d(p("on Thursday at 9am")), [2026, 10, 15])
        XCTAssertEqual(d(p("next Tuesday")), [2026, 10, 13])
        let wed = DateComponents(year: 2026, month: 10, day: 14, hour: 10, minute: 0)
        XCTAssertEqual(d(WhenParser.parse("next Friday", reference: wed)), [2026, 10, 23])
        XCTAssertEqual(d(WhenParser.parse("Friday", reference: wed)), [2026, 10, 16])
        XCTAssertEqual(d(p("this weekend")), [2026, 10, 17])
        XCTAssertEqual(d(p("next week")), [2026, 10, 12])
    }

    func testExplicitDates() {
        XCTAssertEqual(d(p("the 24th")), [2026, 10, 24])
        XCTAssertEqual(d(p("on the twenty fourth")), [2026, 10, 24])
        XCTAssertEqual(d(p("the 3rd")), [2026, 11, 3])
        XCTAssertEqual(d(p("24th of October")), [2026, 10, 24])
        XCTAssertEqual(d(p("January 2nd")), [2027, 1, 2])
        XCTAssertEqual(d(p("5/11")), [2026, 11, 5])
    }

    func testTimes() {
        XCTAssertEqual(t(p("Thursday at 9 a.m.")), [9, 0])
        XCTAssertEqual(t(p("tomorrow at half two")), [14, 30])
        XCTAssertEqual(t(p("tomorrow half past two")), [14, 30])
        XCTAssertEqual(t(p("Friday at 3")), [15, 0])
        XCTAssertEqual(t(p("Monday 10:15")), [10, 15])
        XCTAssertEqual(t(p("Saturday at seven in the evening")), [19, 0])
        XCTAssertEqual(t(p("tomorrow at midday")), [12, 0])
        XCTAssertEqual(t(p("Wednesday at quarter to nine in the morning")), [8, 45])
        XCTAssertEqual(t(p("today at 8")), [20, 0])
        XCTAssertNil(t(p("the 24th")))
    }

    func testAWeekdayThatDoesntMatchTheDateIsFlagged() {
        // 1 November 2026 is a Sunday: the date's kept, the mismatch is pointed out.
        let r = p("Saturday the 1st at 7pm")
        XCTAssertEqual(d(r), [2026, 11, 1])
        XCTAssertEqual(t(r), [19, 0])
        XCTAssertEqual(r?.doubt, "You said Saturday the 1st, but 1 November 2026 is a Sunday")
        XCTAssertNil(p("Sunday the 1st")?.doubt)
        XCTAssertEqual(d(p("Sunday the 1st")), [2026, 11, 1])
        XCTAssertNil(p("Thursday at 9am")?.doubt)
    }

    func testNothingToResolve() {
        XCTAssertNil(p("sometime soon"))
        XCTAssertNil(p("whenever"))
    }
}

final class ActionRulesTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }
    var start: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 0))! }

    func testRulesFindShoppingTodosAndEvents() {
        let t = """
            [15:02:01] You: Okay, we're out of washing up liquid again, and I need to grab some AA batteries for the remote.
            [15:02:12] You: Oh, and mum's birthday is on the 2nd of November, I should get her a card.
            [15:02:20] Speaker 2: Can you pick up some milk and bread on the way back?
            [15:02:25] You: Tom, I'll send you that projector link tonight.
            [15:02:30] You: Honestly, I'll get it sorted.
            """
        let found = ActionRules.ruleActions(ActionRules.candidateLines(t), conversationStart: start, title: nil, calendar: cal)
        let buys = Set(found.filter { $0.type == .buy }.map(\.title))
        XCTAssertTrue(buys.isSuperset(of: ["Washing up liquid", "AA batteries", "Milk", "Bread"]), "\(buys)")
        XCTAssertTrue(found.contains { $0.type == .todo && $0.title == "Send Tom that projector link tonight" }, "\(found)")
        let birthday = found.filter { $0.type == .event }
        XCTAssertEqual(birthday.map(\.title), ["Mum's birthday"])
        XCTAssertEqual(birthday.first?.resolved.map { [$0.month, $0.day] }, [11, 2])
        XCTAssertFalse(found.contains { $0.title.lowercased().contains("sorted") || $0.title == "It" })
    }

    func testARealPhoneTranscript() {
        let t = "[11:18:00] Speech: I'll meet up on Tuesday and then go to the pub and then I need to go to aspen to get some milk and " +
            "cheese and bread. I've got a doctor's appointment on the 13th of August at 1 o'clock. Yeah, I'll see you then."
        let found = ActionRules.ruleActions(ActionRules.candidateLines(t), conversationStart: start, title: nil, calendar: cal, youOnly: false)
        let buys = Set(found.filter { $0.type == .buy }.map { $0.title.lowercased() })
        XCTAssertTrue(buys.isSuperset(of: ["milk", "cheese", "bread"]), "\(found)")
        let doctor = found.filter { $0.type == .event }
        XCTAssertEqual(doctor.count, 1, "\(doctor)")
        XCTAssertTrue(doctor[0].title.lowercased().contains("doctor"))
        XCTAssertEqual(doctor[0].resolved.map { [$0.month, $0.day, $0.hour ?? -1] }, [8, 13, 13])
    }

    func testTheAIsShoppingFiledAsATaskBecomesShopping() {
        let model = ActionRules.fromModel(buy: ["eggs and butter"], todo: ["Pick up milk and bread tomorrow", "Text Sam the address"],
                                          events: [("Vet appointment for Rex", "Tuesday at 4", nil, true)], conversationStart: start, calendar: cal)
        XCTAssertEqual(Set(model.filter { $0.type == .buy }.map(\.title)), ["Eggs", "Butter", "Milk", "Bread"])
        XCTAssertEqual(model.filter { $0.type == .todo }.map(\.title), ["Text Sam the address"])
        XCTAssertEqual(model.first { $0.type == .event }?.resolved.map { [$0.day, $0.hour ?? -1] }, [13, 16])
        let merged = ActionRules.merge(model, [ExtractedAction(type: .buy, title: "Milk"), ExtractedAction(type: .buy, title: "Cheese")])
        XCTAssertEqual(merged.filter { $0.title == "Milk" }.count, 1)
        XCTAssertTrue(merged.contains { $0.title == "Cheese" })
    }
}

final class PlanNoteTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }
    var start: Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 15, minute: 0))! }

    func testProposedPlansAndQuestionedDatesAreMarked() {
        let t = """
            [14:05:00] You: So for mum's birthday, how about the back room at the Crown, Saturday the 1st at 7?
            [14:05:09] Speaker 2: Could do. We'd need to ring them to check it's free.
            [14:06:00] Speaker 2: The garage said the MOT could be Thursday at 9am, but I need to ring them to confirm.
            [14:07:00] You: What about your dentist? Isn't that next Tuesday at half three?
            [14:08:00] You: The remote needs new batteries by the way.
            [14:09:00] You: The vet appointment is booked for Friday at 4, all confirmed.
            """
        let found = ActionRules.ruleActions(ActionRules.candidateLines(t), conversationStart: start, title: nil, calendar: cal, youOnly: false)
        let events = Dictionary(found.filter { $0.type == .event }.map { ($0.title, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(events["Mum's birthday"]?.note, "You said Saturday the 1st, but 1 November 2026 is a Sunday", "\(events)")
        XCTAssertEqual(events["Dentist"]?.note, "Date not certain", "\(events)")
        XCTAssertNil(events["Vet"]?.note, "\(events)")
        XCTAssertTrue(found.contains { $0.type == .buy && $0.title.lowercased() == "batteries" }, "\(found)")
        XCTAssertTrue(found.allSatisfy { $0.source != nil })
        XCTAssertTrue(found.contains { $0.type == .todo && $0.title == "Ring the garage to confirm the MOT" }, "\(found)")
        XCTAssertEqual(events["MOT"]?.note, "Not booked yet", "\(events)")
        let model = ActionRules.fromModel(buy: [], todo: [], events: [("MOT", "Thursday 9am", "the garage", false)],
                                          conversationStart: start, lines: ActionRules.candidateLines(t), calendar: cal)
        XCTAssertEqual(model.first?.note, "Not booked yet")
        XCTAssertTrue(model.first?.source?.contains("garage") ?? false)
    }
}

final class RecapAndRulesTests: XCTestCase {
    var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "Europe/London")!; return c }
    func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: h, minute: m, second: s))! }

    let coffee = """
        [11:40:02] Speaker 1: So the thing is, it has to be monthly or nobody commits.
        [11:40:09] Speaker 2: Monthly works. Where though? My flat's tiny.
        [11:40:21] Speaker 1: Ha! Okay, so, venue. I was thinking the back room at the Crown, because they've got a projector we could use for the rules videos and
        [11:40:30] Speaker 2: Sorry, I have to take this, it's my mum.
        [11:43:51] Speaker 1: Cheers.
        """

    func testFindsTheSentenceThatBrokeOffAndWhoCutIn() {
        let r = QuickRecap.of(coffee, start: at(11, 40), now: at(11, 43, 21), calendar: cal)!
        XCTAssertTrue(r.hasPrefix("Speaker 1 was saying, 3 minutes ago:"), r)
        XCTAssertTrue(r.contains("for the rules videos and\u{2026}\u{201D}"), r)
        XCTAssertTrue(r.contains("Then Speaker 2 cut in: \u{201C}Sorry, I have to take this, it's my mum.\u{201D}"), r)
        XCTAssertFalse(r.contains("Cheers"))
    }

    func testWithoutVoicesItQuotesTheLastThingSaid() {
        let t = "[09:00:00] Speech: Did you book the MOT?\n[09:00:04] Speech: Yes, Thursday at nine, and they'll look at the rattle too."
        let r = QuickRecap.of(t, start: at(9, 0), now: at(9, 0, 30), calendar: cal)!
        XCTAssertTrue(r.hasPrefix("Last thing said, 26 seconds ago:"), r)
        XCTAssertTrue(r.contains("they'll look at the rattle too"), r)
        XCTAssertFalse(r.contains("Teach WTF"))
    }

    func testQuotesLongSpeechFromWhereItBroke() {
        let long = (1...30).map { "Sentence number \($0) is here." }.joined(separator: " ") + " and then I was going to say"
        let q = QuickRecap.quote(long)
        XCTAssertTrue(q.hasPrefix("\u{2026}"))
        XCTAssertTrue(q.hasSuffix("and then I was going to say\u{2026}"))
        XCTAssertLessThanOrEqual(q.count, 210)
    }

    func testCutsLongTalksAtPauses() {
        XCTAssertNil(ChunkRules.end(lengthMs: 20_000, quietMs: 700))
        XCTAssertEqual(ChunkRules.end(lengthMs: 20_000, quietMs: 8_100), .quiet)
        XCTAssertNil(ChunkRules.end(lengthMs: 30_000, quietMs: 200))
        XCTAssertEqual(ChunkRules.end(lengthMs: 30_000, quietMs: 600), .cut)
        XCTAssertNil(ChunkRules.end(lengthMs: 45_000, quietMs: 400))
        XCTAssertEqual(ChunkRules.end(lengthMs: 55_000, quietMs: 300), .cut)
        XCTAssertEqual(ChunkRules.end(lengthMs: 300_001, quietMs: 0), .cut)
    }

    func testTranscriptLinesAndIntents() {
        let u = [Utterance(start: at(10, 0, 1), speaker: "Speech", text: "Hello."), Utterance(start: at(10, 0, 3), speaker: "Speech", text: "How are you?")]
        XCTAssertEqual(TranscriptFormat.lines(u, calendar: cal), "[10:00:01] Speech: Hello. How are you?")
        XCTAssertEqual(TranscriptFormat.compact("[10:00:01] Speech: Hello.\n[10:00:09] Speech: Bye."), "Hello. Bye.")
        XCTAssertEqual(Prompts.intent("WTF was I just on about?"), .latest)
        XCTAssertEqual(Prompts.intent("Summarise my day"), .digest)
        XCTAssertEqual(Prompts.intent("What did I promise Tom?"), .commitments)
        XCTAssertEqual(Prompts.intent("What did Priya say about the venue?"), .focused)
        XCTAssertEqual(TranscriptFormat.clean("\"Hello there.\" Hello there. Bye."), "Hello there. Bye.")
    }

    func testMicTroubleReadsIOSCodes() {
        // As iOS reports them: "Session activation failed" from the background is 561015905.
        XCTAssertEqual(MicTrouble.code("!pla"), 561_015_905)
        XCTAssertEqual(MicTrouble.code("!rec"), 561_145_187)
        XCTAssertEqual(MicTrouble.code("!pri"), 561_017_449)
        XCTAssertEqual(MicTrouble.reason(561_017_449), "a call or another app is using it")
        XCTAssertEqual(MicTrouble.reason(561_015_905), "iOS wouldn\u{2019}t allow it just then")
        XCTAssertNil(MicTrouble.reason(-10875))
    }

    func testMoreWaysOfAskingWhatIWasSaying() {
        for q in ["What were we talking about?", "Where were we?", "Remind me what I was saying", "What was the last thing I said?"] {
            XCTAssertEqual(Prompts.intent(q), .latest, q)
        }
        XCTAssertEqual(Prompts.intent("What were we talking about yesterday?"), .focused)
    }

    func testDuplicatesAreNearlyTheSame() {
        XCTAssertTrue(ActionRules.similar("Milk", "some milk"))
        XCTAssertTrue(ActionRules.similar("Send Tom the link", "send the link to Tom"))
        XCTAssertFalse(ActionRules.similar("Dentist appointment", "Doctor's appointment"))
        XCTAssertFalse(ActionRules.similar("Milk", "Milk chocolate"))
        XCTAssertFalse(ActionRules.similar("Mum's birthday", "Dad's birthday"))
    }

    func testOlderRecapsSayWhichDay() {
        let cal = Calendar(identifier: .gregorian)
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        XCTAssertTrue(QuickRecap.ago(now.addingTimeInterval(-86_400), now: now, calendar: cal).hasPrefix("yesterday at"))
        XCTAssertTrue(QuickRecap.ago(now.addingTimeInterval(-3 * 86_400), now: now, calendar: cal).hasPrefix("on "))
    }

    func testVadHearsSpeechOverQuiet() {
        var vad = EnergyVad()
        let quiet = [Float](repeating: 0.001, count: 480)
        let loud = (0..<480).map { Float(sin(Double($0) / 5) * 0.3) }
        for _ in 0..<20 { _ = vad.isSpeech(quiet) }
        XCTAssertFalse(vad.isSpeech(quiet))
        XCTAssertTrue(vad.isSpeech(loud))
    }

    func testListAnswers() {
        let items = [ListAnswers.Item(type: .buy, title: "Milk"), ListAnswers.Item(type: .todo, title: "Ring the landlord")]
        XCTAssertEqual(ListAnswers.answer("What do I need to buy?", open: items), "To buy:\n\u{2022} Milk")
        XCTAssertNil(ListAnswers.answer("What was I saying about shopping?", open: items))
        XCTAssertNil(ListAnswers.answer("What did I promise Tom?", open: items))
        XCTAssertNil(ListAnswers.answer("What happened in the team meeting?", open: items))
        XCTAssertEqual(ListAnswers.answer("What's on my to-do list?", open: items), "Still to do:\n\u{2022} Ring the landlord")
    }
}
