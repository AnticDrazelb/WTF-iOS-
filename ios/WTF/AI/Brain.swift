import Foundation
import FoundationModels
import WTFCore

@Generable
struct ConversationNotes {
    @Guide(description: "A short, specific title for the conversation, at most 6 words")
    var title: String
    @Guide(description: "2 to 5 short points: what was decided, what was only suggested or still needs doing, and what was left unfinished. Keep each detail with what it was about")
    var points: [String]
}

@Generable
struct Appointment {
    @Guide(description: "What it is, e.g. Dentist check-up")
    var what: String
    @Guide(description: "When, in the words used, e.g. Thursday at half two; empty if not said")
    var when: String
    @Guide(description: "Where, or empty if not said")
    var place: String
    @Guide(description: "true only if it was said to be booked, arranged or confirmed; false if it was only suggested or still needs booking or confirming")
    var booked: Bool
}

@Generable
struct FoundActions {
    @Guide(description: "Groceries or household things someone said to buy from a shop, one item each, e.g. Milk, AA batteries. Not meals out or takeaways, and never people: picking someone up isn't shopping")
    var buy: [String]
    @Guide(description: "Things someone actually said they would do, as short tasks in their words, e.g. Ring the landlord. Add none of your own")
    var todo: [String]
    @Guide(description: "Appointments or plans with a day or a time actually said for them, e.g. MOT at the garage, Thursday 9am. Never assume today")
    var appointments: [Appointment]
}

@Generable
struct CorrectedLines {
    @Guide(description: "Every line, numbered as given, with only clearly misheard words fixed")
    var lines: [String]
}

@Generable
struct TopicStep {
    @Guide(description: "The topics the new lines move through, in order, 1 to 4, each named in 2 to 5 words by what is being talked about, e.g. Where to eat tonight")
    var topics: [String]
    @Guide(description: "For each topic except the last, in the same order: true if it was dropped part-way, unfinished; false if it came to an end")
    var dropped: [Bool]
    @Guide(description: "If a topic was dropped part-way: what I was in the middle of saying about it, under 15 words, starting with 'you were'. Otherwise empty")
    var leftAt: String
    @Guide(description: "Which topic that was, exactly as named in topics. Empty if none was dropped")
    var leftAtTopic: String
    @Guide(description: "For each topic, in the same order: the key details said about it (dates, times, places, names) in under 8 words, e.g. 2 Nov, the Crown, Sat 7pm; or empty")
    var facts: [String]
}

@Generable
struct MemoryNotes {
    @Guide(description: "Who is in the conversation and who they seem to be, e.g. Speaker 2: probably Sarah, organising the party")
    var people: [String]
    @Guide(description: "What was agreed or settled, only if someone actually said so")
    var decided: [String]
    @Guide(description: "Ideas or plans put forward but not settled")
    var suggested: [String]
    @Guide(description: "Things someone said they would do, saying who, e.g. You: ring the garage to confirm the MOT")
    var todo: [String]
    @Guide(description: "Dates, times, places, names and numbers mentioned, each with what it's about, e.g. Mum's party: Saturday 1 Nov, 7pm")
    var facts: [String]
    @Guide(description: "Questions left unanswered, or things dropped part-way")
    var open: [String]
}

@Generable
struct LastingFacts {
    @Guide(description: "Facts worth remembering after today, each a short sentence that makes sense on its own, e.g. Mum's birthday is 2 November. Empty if there are none")
    var facts: [String]
}

/// Apple Intelligence's on-device model: summaries, list items and answers, free and private.
enum Brain {
    /// For answers: the likeliest words, so the same question gets the same answer, without
    /// the inventiveness that adds things nobody said.
    static let steady = GenerationOptions(sampling: nil, temperature: 0.2)

    /// It's summarising what people said, so it shouldn't refuse because someone swore.
    static var model: SystemLanguageModel { SystemLanguageModel(guardrails: .permissiveContentTransformations) }

    /// Nil when it's ready, otherwise what to do about it.
    static var notReadyReason: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: return "This iPhone can't run Apple Intelligence, so WTF quotes what was said instead of summarising it."
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in Settings › Apple Intelligence & Siri for summaries and answers."
            case .modelNotReady: return "Apple Intelligence is still getting ready (downloading). Summaries and answers will start once it's done."
            @unknown default: return "Apple Intelligence isn't available right now."
            }
        }
    }

    static func prewarm() {
        guard notReadyReason == nil else { return }
        LanguageModelSession(model: model, instructions: Prompts.instructions).prewarm()
    }

    static func summarise(_ transcript: String, background: String = "") async throws -> ConversationNotes {
        let session = LanguageModelSession(model: model, instructions: "You write short, plain notes about conversations the user had today.")
        return try await session.respond(to: Prompts.summary(transcript: transcript, background: background), generating: ConversationNotes.self).content
    }

    /// The same in plain text, for when the structured notes are refused: the permissive
    /// guardrails only apply to plain-text answers, so an argument, the news or a doctor's
    /// appointment can still be summarised. "Title: …" then "- " points.
    static func summariseText(_ transcript: String, background: String = "") async throws -> (title: String, points: [String])? {
        let session = LanguageModelSession(model: model, instructions: "You write short, plain notes about conversations the user had today.")
        let prompt = Prompts.summary(transcript: transcript, background: background)
            + "\n\nReply with a first line \"Title: \" and a title of 2 to 6 words, then 2 to 5 short points, each on its own line starting with \"- \"."
        let text = try await session.respond(to: prompt, options: steady).content
        var title: String?
        var points: [String] = []
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if title == nil, line.lowercased().hasPrefix("title:") {
                title = Threads.clean(String(line.dropFirst(6)))
            } else if line.hasPrefix("- ") || line.hasPrefix("\u{2022} ") || line.hasPrefix("* ") {
                points.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
            }
        }
        guard let title else { return nil }
        return (title, points.filter { !$0.isEmpty })
    }

    static func actions(lines: [String], start: Date, background: String = "") async throws -> FoundActions {
        let session = LanguageModelSession(model: model, instructions: "You pick out appointments, shopping and tasks from conversations. Only what was actually said.")
        return try await session.respond(to: Prompts.actions(lines: lines, conversationStart: start, background: background), generating: FoundActions.self).content
    }

    /// A conversation's notes brought up to date with its newest lines.
    static func remember(_ prompt: String) async throws -> ConversationMemory {
        let session = LanguageModelSession(model: model, instructions: "You keep short, accurate notes on a conversation as it happens, for someone who loses track.")
        let n = try await session.respond(to: prompt, generating: MemoryNotes.self).content
        return ConversationMemory(people: n.people, decided: n.decided, suggested: n.suggested, todo: n.todo, facts: n.facts, open: n.open).cleaned()
    }

    /// Facts from a conversation worth keeping after today.
    static func lastingFacts(_ prompt: String) async throws -> [String] {
        let session = LanguageModelSession(model: model, instructions: "You pick out lasting facts from conversations: only what was actually said.")
        return try await session.respond(to: prompt, generating: LastingFacts.self).content.facts
    }

    /// The lines with misheard words fixed from context (checked by Corrections before use).
    static func correct(_ lines: [String], doubts: [Doubt], known: [String], learned: [LearnedFix]) async throws -> [String] {
        let session = LanguageModelSession(model: model, instructions: "You fix words that speech recognition misheard, and change nothing else.")
        let prompt = Corrections.prompt(lines, doubts: doubts, known: known, learned: learned)
        return try await session.respond(to: prompt, generating: CorrectedLines.self).content.lines
    }

    /// Which topic the newest lines belong to: the thread map's step.
    static func topic(_ prompt: String) async throws -> TopicChange {
        let session = LanguageModelSession(model: model, instructions: "You follow the topics of a conversation as it wanders, for someone who loses their train of thought.")
        let step = try await session.respond(to: prompt, generating: TopicStep.self).content
        return TopicChange(topics: step.topics, dropped: step.dropped, leftAt: step.leftAt, leftAtTopic: step.leftAtTopic, facts: step.facts)
    }

    /// "Your Day": a few sentences on a whole day, from its conversations' notes (Prompts.day).
    static func day(_ prompt: String) async throws -> String {
        let session = LanguageModelSession(model: model, instructions: "You look back over someone's day for them, from notes on their conversations, in a few plain sentences. Start with the recap itself, and use only what's in the notes.")
        let response = try await session.respond(to: prompt, options: steady)
        return Prompts.tidy(response.content)
    }

    /// A short answer to read aloud, given up on after [seconds].
    static func quick(_ prompt: String, seconds: Double) async -> String? {
        await withDeadline(seconds) {
            let session = LanguageModelSession(model: model, instructions: Prompts.instructions)
            return await Log.attempt("Spoken answer") {
                let response = try await session.respond(to: prompt, options: steady)
                return Prompts.tidy(response.content)
            }
        }
    }

    /// The answer as it's written, each element the whole answer so far.
    static func ask(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = LanguageModelSession(model: model, instructions: Prompts.instructions)
                    for try await partial in session.streamResponse(to: prompt, options: steady) {
                        continuation.yield(partial.content)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
