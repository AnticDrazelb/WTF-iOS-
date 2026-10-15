import XCTest
@testable import WTFCore

final class VoicesTests: XCTestCase {
    /// Voiceprints along different axes are different people; a little noise is the same one.
    func print(_ axis: Int, _ wobble: Float = 0) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[axis] = 1
        v[(axis + 1) % 8] = wobble
        return VoiceMath.normalised(v)
    }

    func testNewVoicesAreNumberedInTheOrderTheySpoke() {
        var heard: [Voiceprint] = []
        let got = VoiceMatcher.label([
            LocalVoice(id: "S1", print: print(0), seconds: 20, firstAt: 6),
            LocalVoice(id: "S2", print: print(1), seconds: 4, firstAt: 1),
        ], heard: &heard, known: [])
        XCTAssertEqual(got, ["S2": "Speaker 1", "S1": "Speaker 2"])
        XCTAssertEqual(heard.map(\.label), ["Speaker 1", "Speaker 2"])
    }

    func testTheSameVoiceInTheNextRecordingKeepsItsNumber() {
        var heard = [Voiceprint(label: "Speaker 1", print: print(0), seconds: 10),
                     Voiceprint(label: "Speaker 2", print: print(1), seconds: 10)]
        // The recording numbers its voices afresh: its S1 is the conversation's Speaker 2.
        let got = VoiceMatcher.label([
            LocalVoice(id: "S1", print: print(1, 0.3), seconds: 8, firstAt: 0),
            LocalVoice(id: "S2", print: print(4), seconds: 6, firstAt: 3),
        ], heard: &heard, known: [])
        XCTAssertEqual(got, ["S1": "Speaker 2", "S2": "Speaker 3"])
        XCTAssertEqual(heard[1].seconds, 18)
    }

    func testOneVoiceSplitInTwoComesBackTogether() {
        // The splitter sometimes hears one person as two (shouting, a cough): both match.
        var heard = [Voiceprint(label: "Speaker 1", print: print(0), seconds: 30)]
        let got = VoiceMatcher.label([
            LocalVoice(id: "S1", print: print(0, 0.2), seconds: 10, firstAt: 0),
            LocalVoice(id: "S2", print: print(0, 0.5), seconds: 5, firstAt: 4),
        ], heard: &heard, known: [])
        XCTAssertEqual(got, ["S1": "Speaker 1", "S2": "Speaker 1"])
    }

    func testASnippetTooShortToBeSureJoinsTheClosestVoice() {
        var heard = [Voiceprint(label: "Speaker 1", print: print(0), seconds: 30)]
        let got = VoiceMatcher.label([LocalVoice(id: "S1", print: print(5), seconds: 0.8, firstAt: 0)], heard: &heard, known: [])
        XCTAssertEqual(got, ["S1": "Speaker 1"])
    }

    func testNamedPeopleAndYouAreRecognised() {
        var heard: [Voiceprint] = []
        let known = [KnownVoice(name: "Me", print: print(2), isMe: true), KnownVoice(name: "Sarah", print: print(3), isMe: false)]
        let got = VoiceMatcher.label([
            LocalVoice(id: "S1", print: print(3, 0.4), seconds: 9, firstAt: 0),
            LocalVoice(id: "S2", print: print(2, 0.2), seconds: 12, firstAt: 2),
            LocalVoice(id: "S3", print: print(6), seconds: 5, firstAt: 5),
        ], heard: &heard, known: known)
        XCTAssertEqual(got, ["S1": "Sarah", "S2": "You", "S3": "Speaker 1"])
        XCTAssertEqual(VoiceMatcher.match(KnownVoice(name: "Tom", print: print(6, 0.1), isMe: false), in: heard), "Speaker 1")
        XCTAssertNil(VoiceMatcher.match(KnownVoice(name: "Tom", print: print(7), isMe: false), in: heard))
    }

    func testWordsGoToWhoeverWasSpeaking() {
        let words = [("So ", 0.0), ("I ", 0.3), ("was ", 0.5), ("saying ", 0.7), ("that. ", 1.0),
                     ("Right, ", 2.0), ("sure. ", 2.4), ("Anyway ", 3.5), ("yeah.", 3.9)]
            .map { SpeakerAlign.Word(start: $0.1, end: $0.1 + 0.25, text: $0.0) }
        let turns = [SpeakerAlign.Turn(start: 0, end: 1.3, speaker: "A"),
                     SpeakerAlign.Turn(start: 1.9, end: 2.7, speaker: "B"),
                     // A blip of B inside A's last turn is smoothed away.
                     SpeakerAlign.Turn(start: 3.4, end: 3.8, speaker: "A"),
                     SpeakerAlign.Turn(start: 3.8, end: 4.0, speaker: "B"),
                     SpeakerAlign.Turn(start: 4.0, end: 4.4, speaker: "A")]
        let said = SpeakerAlign.assign(words, turns: turns, fallback: "A")
        XCTAssertEqual(said.map(\.speaker), ["A", "B", "A"])
        XCTAssertEqual(said.map(\.text), ["So I was saying that.", "Right, sure.", "Anyway yeah."])
        XCTAssertEqual(said[1].start, 2.0)

        let blip = [SpeakerAlign.Word(start: 0, end: 1, text: "Hello "), SpeakerAlign.Word(start: 1, end: 1.3, text: "there "),
                    SpeakerAlign.Word(start: 1.3, end: 2, text: "you.")]
        let t = [SpeakerAlign.Turn(start: 0, end: 1, speaker: "A"), SpeakerAlign.Turn(start: 1, end: 1.3, speaker: "B"),
                 SpeakerAlign.Turn(start: 1.3, end: 2, speaker: "A")]
        XCTAssertEqual(SpeakerAlign.assign(blip, turns: t, fallback: "A").map(\.speaker), ["A"])
        XCTAssertEqual(SpeakerAlign.join(["Hello", "there,", "it's", "\u{00A3}3.50", "."]), "Hello there, it's \u{00A3}3.50.")
        XCTAssertEqual(SpeakerAlign.join([" Hello", " there", "."]), "Hello there.")
        // No turns at all: whoever was speaking before.
        XCTAssertEqual(SpeakerAlign.assign(blip, turns: [], fallback: "Speaker 2").map(\.speaker), ["Speaker 2"])
    }

    func testASpeakerChangeMarkedLateSnapsToTheSentenceEnd() {
        // The splitter says B starts at 3.0, but B's first word "Yeah," came at 2.5, after A's full stop.
        let w = [("inside ", 0.0), ("prison. ", 1.8), ("Yeah, ", 2.5), ("it's ", 3.1), ("incredible.", 3.4)]
            .map { SpeakerAlign.Word(start: $0.1, end: $0.1 + 0.3, text: $0.0) }
        let turns = [SpeakerAlign.Turn(start: 0, end: 3.0, speaker: "A"), SpeakerAlign.Turn(start: 3.0, end: 4, speaker: "B")]
        let said = SpeakerAlign.assign(w, turns: turns, fallback: "A")
        XCTAssertEqual(said.map(\.text), ["inside prison.", "Yeah, it's incredible."])
        XCTAssertEqual(said[1].start, 2.5)
        // No sentence end nearby: left as the splitter said.
        let w2 = [("we ", 0.0), ("went ", 0.4), ("to ", 0.8), ("school ", 1.0), ("in ", 2.0), ("late ", 2.3)]
            .map { SpeakerAlign.Word(start: $0.1, end: $0.1 + 0.2, text: $0.0) }
        let t2 = [SpeakerAlign.Turn(start: 0, end: 1.5, speaker: "A"), SpeakerAlign.Turn(start: 1.5, end: 3, speaker: "B")]
        XCTAssertEqual(SpeakerAlign.assign(w2, turns: t2, fallback: "A").map(\.text), ["we went to school", "in late"])
        XCTAssertEqual(SpeakerAlign.tidy(". Cool. There's room."), "Cool. There's room.")
        XCTAssertEqual(SpeakerAlign.tidy("in Birmingham?."), "in Birmingham?")
    }

    func testNamingAVoiceRewritesItsLines() {
        let t = "[10:00:01] Speaker 1: Hi.\n[10:00:03] Speaker 12: Hello.\n[10:00:05] Speaker 1: Bye: now."
        XCTAssertEqual(Labels.rename(t, from: "Speaker 1", to: "Sarah"),
                       "[10:00:01] Sarah: Hi.\n[10:00:03] Speaker 12: Hello.\n[10:00:05] Sarah: Bye: now.")
        XCTAssertEqual(Labels.renameInText("Speaker 1 and Speaker 12 agreed.", from: "Speaker 1", to: "Sarah"), "Sarah and Speaker 12 agreed.")
        XCTAssertEqual(Labels.speakers(in: t), ["Speaker 1", "Speaker 12"])
        XCTAssertEqual(Labels.cleanName("  Auntie: Jo "), "Auntie Jo")
        XCTAssertEqual(Labels.cleanName("me"), "You")
        XCTAssertNil(Labels.cleanName("Speaker 3"))
        XCTAssertNil(Labels.cleanName(" "))
    }
}

final class ThreadsTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
    func testATangentLeavesTheThreadHangingAndComingBackPicksItUp() {
        // "Chinese food? ... Japanese? I like samurai ... The Last Samurai ... Mission Impossible ... oh yeah, Chinese food."
        let change = TopicChange(topics: ["Chinese food", "Japanese food", "Films", "chinese food."], dropped: [true, false, false],
                                 leftAt: "you were saying where to get Chinese food")
        var threads = Threads.apply(change, to: [], from: at(0), to: at(40))
        XCTAssertEqual(threads.map(\.title), ["Chinese food", "Japanese food", "Films", "Chinese food"])
        XCTAssertEqual(threads.map(\.status), [.resumed, .finished, .finished, .current])
        XCTAssertEqual(threads[0].leftAt, "you were saying where to get Chinese food")
        XCTAssertEqual(threads[1].start, at(10))
        // Carrying on: the current one just gets longer.
        threads = Threads.apply(TopicChange(topics: ["Chinese food"]), to: threads, from: at(40), to: at(60))
        XCTAssertEqual(threads.count, 4)
        XCTAssertEqual(threads[3].end, at(60))
        // Off on another tangent mid-sentence, left hanging.
        threads = Threads.apply(TopicChange(topics: ["Chinese food", "The MOT"], dropped: [true], leftAt: "you were about to pick a place"),
                                to: threads, from: at(60), to: at(80))
        XCTAssertEqual(threads.suffix(2).map(\.status), [.hanging, .current])
        XCTAssertEqual(Threads.hanging(threads).map(\.title), ["Chinese food"])
        XCTAssertTrue(Threads.prompt(threads, recent: "", new: "[10:00:00] You: Anyway.").contains("(dropped part-way)"))
        // The model says which dropped topic its "you were" is about.
        let two = Threads.apply(TopicChange(topics: ["Birthday", "MOT", "Shopping"], dropped: [true, true],
                                            leftAt: "you were booking the Crown", leftAtTopic: "birthday"), to: [], from: at(0), to: at(30))
        XCTAssertEqual(two.map(\.leftAt), ["you were booking the Crown", "", nil])
        XCTAssertEqual(Threads.close(threads).last?.status, .finished)
        // Nothing usable: unchanged but longer.
        XCTAssertEqual(Threads.apply(TopicChange(topics: [" "]), to: threads, from: at(80), to: at(90)).count, threads.count)
    }

    func testSpokenRecapIsShort() {
        let t = """
            [10:00:00] Speaker 2: So what did you get her in the end?
            [10:00:03] You: Well I was going to get the scarf but then I saw this lovely little
            [10:00:08] Speaker 2: Oh, is that the MOT reminder?
            """
        let ten = Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: t0)!
        let s = QuickRecap.spoken(t, start: ten, now: ten.addingTimeInterval(20))!
        XCTAssertTrue(s.hasPrefix("You were saying, 17 seconds ago: Well I was going"), s)
        XCTAssertTrue(s.hasSuffix("lovely little\u{2026} Then Speaker 2 cut in."), s)
    }

    func testGettingAnAnswerIsntShopping() {
        let lines = ["[11:43:10] Speaker 1: We need to get a good answer on that.", "[11:43:20] Speaker 1: Can you pick up some milk and bread?"]
        let found = ActionRules.ruleActions(lines, conversationStart: Date(), title: nil, youOnly: false).filter { $0.type == .buy }.map(\.title)
        XCTAssertEqual(Set(found), ["Milk", "Bread"]) // (repeats are merged later)
    }

    func testEatingOutAndVaguePlansArentListItems() {
        let lines = ["[12:50:00] Speaker 1: I want to go and grab some Chinese food from a restaurant later."]
        XCTAssertTrue(ActionRules.ruleActions(lines, conversationStart: Date(), title: nil, youOnly: false).filter { $0.type == .buy }.isEmpty)
        let model = ActionRules.fromModel(buy: [], todo: [], events: [("Samurai", "Nothing", nil, false), ("Chinese food", "Later", "Restaurant", false),
                                                                     ("Dentist", "Thursday at 3", nil, true)], conversationStart: Date())
        XCTAssertEqual(model.map(\.title), ["Dentist"])
    }

    func testDatesComeFromTheirOwnSentence() {
        // Monday 12 October 2026, as recognised on the phone (with its slips).
        let ref = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 13, minute: 16))!
        let lines = [
            "[13:16:00] Speech: Right, so we need to sort mom's birthday. It's on the 2nd of November that's Saturday, so I was thinking we bucked the back room at the crown for Saturday the first at seven in the evening. Does that work?",
            "[13:17:30] Speaker 1: I'll order it tonight. Remind me I do that. Yeah, do it tonight or you forget. What about your dentist? Isn't that next Tuesday? Oh God, yes. Next Tuesday half three.",
        ]
        let events = ActionRules.ruleActions(lines, conversationStart: ref, title: nil, youOnly: false).filter { $0.type == .event }
        let byTitle = Dictionary(events.map { ($0.title, $0.resolved.map { [$0.month, $0.day] } ?? []) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byTitle["Mom's birthday"], [11, 2])
        XCTAssertEqual(byTitle["Dentist"], [10, 20])
        let merged = ["[13:17:30] Speaker 1: Yeah, do it tonight or you'll forget what about your dentist? Isn't that next Tuesday at half three? I will do that after dinner tonight."]
        let e2 = ActionRules.ruleActions(merged, conversationStart: ref, title: nil, youOnly: false).filter { $0.type == .event }
        XCTAssertEqual(e2.map(\.title), ["Dentist"])
        XCTAssertEqual(e2.first?.resolved.map { [$0.month, $0.day, $0.hour ?? -1] }, [10, 20, 15])
        XCTAssertEqual(TranscriptFormat.clean("Right, #um so we need #oh, did you"), "Right, so we need did you")
    }

    func testSentencesAboutATopic() {
        let lines = "[13:16:00] Speech: Right, so we need to sort mom's birthday. It's on the 2nd of November. Did you get the MOT sorted? The garage said Thursday."
        XCTAssertEqual(Prompts.sentences(about: "Garage appointment", in: lines), ["The garage said Thursday."])
        XCTAssertEqual(Prompts.sentences(about: "Mom's birthday", in: lines), ["Right, so we need to sort mom's birthday."])
        XCTAssertTrue(Prompts.thread("MOT", leftAt: nil, lines: lines).contains("remind me where I'd got to with MOT"))
    }

    func testCorrectionsFixAWordButNeverRewrite() {
        let line = "[13:16:00] Speech: so I was thinking we bucked the back room at the crown for Saturday the first at seven"
        let fixed = Corrections.apply(["1. so I was thinking we booked the back room at the Crown for Saturday the first at seven"], to: [line])
        XCTAssertEqual(fixed, ["[13:16:00] Speech: so I was thinking we booked the back room at the Crown for Saturday the first at seven"])
        // A rewrite is refused.
        let rewrite = Corrections.apply(["We'll reserve a private room at the Crown pub on Saturday evening."], to: [line])
        XCTAssertEqual(rewrite, [line])
        XCTAssertTrue(Corrections.prompt([line]).contains("1. so I was thinking we bucked"))
    }

    func testTopicsAreSubjectsNotPhrases() {
        let t0 = Date(timeIntervalSince1970: 0)
        var threads = Threads.apply(TopicChange(topics: ["Mum's birthday", "Perfect", "Quick tangent"]), to: [], from: t0, to: t0.addingTimeInterval(20))
        XCTAssertEqual(threads.map(\.title), ["Mum's birthday"])
        threads = Threads.apply(TopicChange(topics: ["Mom's birthday present"]), to: threads, from: t0.addingTimeInterval(20), to: t0.addingTimeInterval(40))
        XCTAssertEqual(threads.count, 1, "\(threads.map(\.title))")
    }

    func testTopicDetailsAndTangentLayout() {
        let t0 = Date(timeIntervalSince1970: 0)
        var threads = Threads.apply(TopicChange(topics: ["Mum's birthday", "The MOT"], dropped: [true], facts: ["2 Nov", "Thursday 9am"]),
                                    to: [], from: t0, to: t0.addingTimeInterval(20))
        threads = Threads.apply(TopicChange(topics: ["The MOT", "Mum's birthday"], facts: ["the garage", "Crown, Sat 1st 7pm"]),
                                to: threads, from: t0.addingTimeInterval(20), to: t0.addingTimeInterval(40))
        XCTAssertEqual(threads.map(\.facts), ["2 Nov", "Thursday 9am · the garage", "Crown, Sat 1st 7pm"])
        XCTAssertEqual(Threads.layout(threads).map(\.tangent), [false, true, false])
    }

    func testVocabulary() {
        let w = Vocabulary.words(people: ["Sarah", "You", "sarah"], items: ["Ring Dave about the van", "Buy milk at Asda"], limit: 6)
        XCTAssertEqual(w, ["Sarah", "Dave", "Asda", "Tesco", "Sainsbury's", "Aldi"])
    }
}
