import Foundation
import SwiftData
import WTFCore

/// Sample data and a starting screen, for the Simulator screenshots that CI takes to check the
/// app's look (.github/workflows/screenshots.yml). Only when launched with `-WTFDemo YES`: an
/// iPhone never sees it.
@MainActor
enum Demo {
    static var on: Bool { UserDefaults.standard.bool(forKey: "WTFDemo") }

    /// The screen to open on: `-WTFScreen ask|timeline|conversation|lists|settings`.
    static var screen: String { UserDefaults.standard.string(forKey: "WTFScreen") ?? "ask" }

    static func prepare(_ model: AppModel) {
        guard on else { return }
        let context = model.container.mainContext
        if ((try? context.fetchCount(FetchDescriptor<Conversation>())) ?? 0) == 0 { seed(context, model) }
        switch screen {
        case "timeline": model.tab = 1
        case "conversation":
            model.tab = 1
            var latest = FetchDescriptor<Conversation>(sortBy: [SortDescriptor(\.end, order: .reverse)])
            latest.fetchLimit = 1
            if let c = (try? context.fetch(latest))?.first { model.timelinePath.append(c) }
        case "lists": model.tab = 2
        case "settings": model.tab = 3
        default: model.tab = 0
        }
    }

    private static func seed(_ context: ModelContext, _ model: AppModel) {
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func line(_ at: Date, _ who: String, _ text: String) -> String {
            TranscriptFormat.lines([Utterance(start: at, speaker: who, text: text)])
        }

        let party = Conversation(start: ago(42), end: ago(6), transcript: [
            line(ago(42), Labels.me, "So for Mum's birthday I was thinking the back room at the Crown, they've got that long table."),
            line(ago(40), "Sarah", "Saturday the second? I can do the cake if you sort the booking."),
            line(ago(37), Labels.me, "Yes, I'll ring them tomorrow. Oh, and we need candles, and I was going to say about the"),
            line(ago(36), "Sarah", "Sorry, that's the garage. They want to know about the MOT."),
            line(ago(30), Labels.me, "Tell them Thursday at nine is fine, and ask them to look at the rattle too."),
            line(ago(8), Labels.me, "Right, where was I? The party. Seven o'clock, back room, about twenty people."),
        ].joined(separator: "\n"))
        party.title = "Mum's birthday at the Crown"
        party.summary = "\u{2022} Party in the back room at the Crown, Saturday 2nd, 7pm, about 20 people\n\u{2022} Sarah's doing the cake; you're ringing the Crown to book\n\u{2022} MOT moved to Thursday at 9, with the rattle looked at"
        party.threads = [
            TopicThread(title: "Mum's birthday", start: ago(42), end: ago(37), status: .hanging, leftAt: "and I was going to say about the"),
            TopicThread(title: "The MOT", start: ago(36), end: ago(30), status: .finished),
            TopicThread(title: "Party plans", start: ago(8), end: ago(6), status: .current),
        ]
        party.closed = true

        let standup = Conversation(start: ago(180), end: ago(165), transcript: [
            line(ago(180), Labels.me, "Morning. The release is ready apart from the settings screen."),
            line(ago(176), "Speaker 2", "Can you send me the build before lunch? I'll test it on the old iPhone."),
            line(ago(170), Labels.me, "Will do. I'll also write up the notes for Friday."),
        ].joined(separator: "\n"))
        standup.title = "Morning stand-up"
        standup.summary = "\u{2022} Release ready apart from the settings screen\n\u{2022} You're sending the build before lunch and writing Friday's notes"
        standup.closed = true

        let yesterday = Conversation(start: ago(26 * 60), end: ago(26 * 60 - 12), transcript: line(ago(26 * 60), Labels.me, "We're out of milk, bread and coffee, can you pick some up on the way back?"))
        yesterday.title = "Shopping on the way home"
        yesterday.summary = "\u{2022} Milk, bread and coffee needed"
        yesterday.closed = true

        for c in [party, standup, yesterday] { context.insert(c) }

        let calendar = Calendar.current
        let saturday = calendar.nextDate(after: now, matching: DateComponents(hour: 19, weekday: 7), matchingPolicy: .nextTime)
        let thursday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, weekday: 5), matchingPolicy: .nextTime)
        let items: [ActionItem] = [
            ActionItem(type: "EVENT", title: "Mum's birthday party", start: saturday, place: "The Crown", quote: "the back room at the Crown", status: "accepted", conversationID: party.id),
            ActionItem(type: "EVENT", title: "MOT", start: thursday, quote: "Thursday at nine is fine", status: "suggested", conversationID: party.id),
            ActionItem(type: "TODO", title: "Ring the Crown to book", status: "accepted", conversationID: party.id),
            ActionItem(type: "TODO", title: "Send the build before lunch", status: "accepted", conversationID: standup.id),
            ActionItem(type: "BUY", title: "Candles", status: "accepted", conversationID: party.id),
            ActionItem(type: "BUY", title: "Milk", status: "accepted", conversationID: yesterday.id),
            ActionItem(type: "BUY", title: "Coffee", status: "suggested", conversationID: yesterday.id),
        ]
        for i in items { context.insert(i) }
        context.insert(Fact(text: "Mum's birthday is 2 November"))
        context.insert(Fact(text: "Sarah is your sister"))
        try? context.save()

        model.messages = [
            ChatMessage(fromUser: true, text: AppModel.quickQuestion, date: ago(5), about: [party.id]),
            ChatMessage(fromUser: false, text: "You were saying, 37 minutes ago:\n\u{201C}Yes, I'll ring them tomorrow. Oh, and we need candles, and I was going to say about the\u{2026}\u{201D}\n\nThen Sarah cut in: \u{201C}Sorry, that's the garage. They want to know about the MOT.\u{201D}", date: ago(5), about: [party.id]),
            ChatMessage(fromUser: false, text: "You were planning Mum's birthday at the Crown and were about to add something after the candles when Sarah brought up the MOT.", date: ago(5), about: [party.id]),
        ]
        model.heardSomething(true)
    }
}
