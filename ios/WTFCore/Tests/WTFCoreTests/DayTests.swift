import XCTest
@testable import WTFCore

final class DayTests: XCTestCase {
    let morning = Date(timeIntervalSince1970: 1_760_000_000)

    func testTheDayIsGatheredOnceEachWithWhereItCameFrom() {
        let notes = [
            DayNote(start: morning, title: "The MOT", decided: ["MOT on Thursday at 9", "Use the garage on Mill Lane"], todo: ["You: ring the garage to confirm"]),
            DayNote(start: morning.addingTimeInterval(3600), title: "Mum's party", decided: ["mot on thursday at 9!", "Party at the Crown, Saturday 7pm"],
                    todo: ["\u{2022} you: order the cake"]),
        ]
        let decided = DayReview.gather(notes) { $0.decided }
        XCTAssertEqual(decided.map(\.text), ["MOT on Thursday at 9", "Use the garage on Mill Lane", "Party at the Crown, Saturday 7pm"])
        XCTAssertEqual(decided.map(\.from), [0, 0, 1])
        XCTAssertEqual(DayReview.gather(notes) { $0.todo }.map(\.text), ["Ring the garage to confirm", "Order the cake"])
        XCTAssertEqual(DayReview.gather(notes, limit: 1) { $0.decided }.count, 1)
        XCTAssertTrue(DayReview.gather(notes) { _ in ["  ", "\u{2022}"] }.isEmpty)
    }

    func testWithoutAIItSaysHowManyWhenAndWhatAbout() {
        let time: (Date) -> String = { "\(Int($0.timeIntervalSince(self.morning) / 3600) + 9):00" }
        let one = [DayNote(start: morning, title: "The MOT")]
        XCTAssertEqual(DayReview.plain(one, time: time), "One conversation, at 9:00: The MOT.")
        let six = (0..<6).map { DayNote(start: morning.addingTimeInterval(Double(5 - $0) * 3600), title: "Topic \(5 - $0)") }
        XCTAssertEqual(DayReview.plain(six, time: time),
                       "6 conversations, between 9:00 and 14:00: Topic 0, Topic 1, Topic 2, Topic 3 and 2 more.")
        XCTAssertEqual(DayReview.plain([], time: time), "Nothing was heard.")
    }

    func testTheDayPromptNamesEveryConversationAndFits() {
        let long = String(repeating: "a detail that goes on ", count: 12)
        let notes = (0..<12).map { i in
            DayNote(start: morning.addingTimeInterval(Double(i) * 1800), title: "Topic \(i)", points: [long, long],
                    decided: ["Decided thing \(i)"], todo: ["You: job \(i)"], hanging: ["Loose end \(i)"])
        }
        let prompt = Prompts.day(notes, today: true, budget: 600)
        for i in 0..<12 { XCTAssertTrue(prompt.contains("Topic \(i)\n") || prompt.hasSuffix("Topic \(i)"), "Topic \(i) missing") }
        // Settled things go in before the rest of the summary, from every conversation.
        for i in 0..<12 { XCTAssertTrue(prompt.contains("Decided: Decided thing \(i)")) }
        XCTAssertTrue(prompt.contains("To do: Job 0"))
        XCTAssertTrue(prompt.contains("today so far"))
        let notesPart = prompt.components(separatedBy: "\n\nIn 2 or 3")[0]
        XCTAssertLessThanOrEqual(Prompts.tokens(notesPart), 600 + 60) // the budget, give or take the heading
        XCTAssertTrue(Prompts.day(notes, today: false).contains("that day"))
    }

    func testAnOverlongDayKeepsItsLatestConversations() {
        let notes = (0..<400).map { DayNote(start: morning.addingTimeInterval(Double($0) * 60), title: "Conversation number \($0)") }
        let prompt = Prompts.day(notes, today: false, budget: 300)
        XCTAssertTrue(prompt.contains("Conversation number 399"))
        XCTAssertFalse(prompt.contains("Conversation number 0\n"))
        XCTAssertTrue(prompt.contains("earlier conversations left out"))
    }
}
