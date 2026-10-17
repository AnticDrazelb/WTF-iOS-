import XCTest
@testable import WTFCore

/// Cases found in the seventh review: "Tuesday next week" taken as this week, morning
/// children's and birthday parties made evening ones, and "what did I just say I'd do".
final class SeventhReviewTests: XCTestCase {
    // Monday 19 October 2026, 10:00
    let ref = DateComponents(year: 2026, month: 10, day: 19, hour: 10, minute: 0)
    func p(_ s: String) -> WhenResult? { WhenParser.parse(s, reference: ref) }
    func day(_ r: WhenResult?) -> [Int]? { r.map { [$0.month, $0.day] } }
    var london: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/London")!
        c.locale = Locale(identifier: "en_GB")
        return c
    }
    func found(_ said: String) -> [ExtractedAction] {
        ActionRules.ruleActions(["[10:00:00] Speaker 1: " + said], conversationStart: london.date(from: ref)!, title: nil, calendar: london, youOnly: false)
    }

    func testWeekdayNextWeekIsInTheFollowingWeek() {
        XCTAssertEqual(day(p("My appointment is Tuesday next week.")), [10, 27])
        XCTAssertEqual(day(p("The meeting is on Thursday next week")), [10, 29])
        XCTAssertEqual(day(p("Next week on Wednesday")), [10, 28])
        XCTAssertEqual(day(p("Monday next week")), [10, 26])
        XCTAssertEqual(day(p("Sunday of next week")), [11, 1])
        XCTAssertNil(p("Tuesday next week")?.doubt)
        // Unchanged: a weekday on its own is the coming one.
        XCTAssertEqual(day(p("Tuesday")), [10, 20])
        XCTAssertEqual(day(p("Next Tuesday")), [10, 27])
    }

    func testMorningPartiesStayInTheMorning() {
        let kids = found("Kids' party on Saturday at 10.").first { $0.type == .event }
        XCTAssertEqual(kids?.resolved?.hour, 10)
        let ella = found("Ella's birthday party is on Saturday at 10.").first { $0.type == .event }
        XCTAssertEqual(ella?.resolved?.hour, 10)
        // A party on its own is still an evening one.
        let party = found("The party is on Saturday at 9.").first { $0.type == .event }
        XCTAssertEqual(party?.resolved?.hour, 21)
        // Words further back don't count: the dentist isn't an evening plan.
        let dentist = found("The pub was fun, and the dentist is on Saturday at 10.").first { $0.title == "Dentist" }
        XCTAssertEqual(dentist?.resolved?.hour, 10)
    }

    func testJustSaidIsTheLatest() {
        XCTAssertEqual(Prompts.intent("What did I just say I'd do?"), .latest)
        XCTAssertEqual(Prompts.intent("What did I say I'd do today?"), .commitments)
        XCTAssertEqual(Prompts.intent("What did I promise?"), .commitments)
    }
}
