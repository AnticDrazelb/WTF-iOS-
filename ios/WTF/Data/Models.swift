import Foundation
import SwiftData
import WTFCore

/// A stretch of recorded speech waiting for, or done with, transcription.
@Model
final class Chunk {
    var start: Date
    var end: Date
    /// The audio file, until it's transcribed (then deleted).
    var path: String?
    /// pending, done, empty, failed
    var status: String
    var attempts: Int
    var conversationID: UUID?

    init(start: Date, end: Date, path: String) {
        self.start = start; self.end = end; self.path = path; self.status = "pending"; self.attempts = 0
    }
}

/// Speech grouped by silence: the unit of the Timeline.
@Model
final class Conversation {
    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date
    var title: String?
    var summary: String?
    /// Lines like "[11:40:02] Speech: …", the whole conversation.
    var transcript: String
    /// A newer conversation has started, so this one's finished.
    var closed: Bool
    /// The voices heard so far ([Voiceprint] as JSON), so the next recording knows who's who.
    var voices: Data?

    init(start: Date, end: Date, transcript: String) {
        self.id = UUID(); self.start = start; self.end = end; self.transcript = transcript; self.closed = false
    }

    /// The thread map ([TopicThread] as JSON): the topics it wandered through.
    var threadData: Data?

    var threads: [TopicThread] {
        get { threadData.flatMap { try? JSONDecoder().decode([TopicThread].self, from: $0) } ?? [] }
        set { threadData = try? JSONEncoder().encode(newValue) }
    }

    /// What it's been established so far ([ConversationMemory] as JSON), kept up to date as it goes.
    var memoryData: Data?

    var memory: ConversationMemory {
        get { memoryData.flatMap { try? JSONDecoder().decode(ConversationMemory.self, from: $0) } ?? .empty }
        set { memoryData = try? JSONEncoder().encode(newValue) }
    }

    /// You've fixed words in it yourself: it's kept as it is, not transcribed afresh at the end.
    var userEdited: Bool?

    /// Words you fixed in it yourself ([LearnedFix] as JSON).
    var fixData: Data?

    var fixes: [LearnedFix] {
        get { fixData.flatMap { try? JSONDecoder().decode([LearnedFix].self, from: $0) } ?? [] }
        set { fixData = try? JSONEncoder().encode(newValue) }
    }

    var voiceprints: [Voiceprint] {
        get { voices.flatMap { try? JSONDecoder().decode([Voiceprint].self, from: $0) } ?? [] }
        set { voices = try? JSONEncoder().encode(newValue) }
    }
}

/// Someone you've named, or you: recognised by voice in every conversation from then on.
@Model
final class Person {
    @Attribute(.unique) var id: UUID
    var name: String
    /// Average voiceprint, as Float32s.
    var voiceprint: Data
    var seconds: Double
    var isMe: Bool

    init(name: String, print: [Float], seconds: Double, isMe: Bool) {
        self.id = UUID(); self.name = name; self.voiceprint = Person.pack(print); self.seconds = seconds; self.isMe = isMe
    }

    var voice: KnownVoice { KnownVoice(name: name, print: Person.unpack(voiceprint), isMe: isMe) }

    /// Folds more of their voice into the average.
    func add(_ more: [Float], seconds extra: Double) {
        var v = Voiceprint(label: name, print: Person.unpack(voiceprint), seconds: seconds)
        v.add(more, seconds: extra)
        voiceprint = Person.pack(v.print)
        seconds = v.seconds
    }

    static func pack(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func unpack(_ d: Data) -> [Float] {
        d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

/// An appointment, something to buy or something to do, heard in a conversation.
@Model
final class ActionItem {
    @Attribute(.unique) var id: UUID
    /// EVENT, BUY or TODO
    var type: String
    var title: String
    var start: Date?
    var allDay: Bool
    var place: String?
    /// The words it was heard in.
    var quote: String?
    /// When it was said.
    var heardAt: Date?
    /// What to check before relying on it: "Not booked yet", "Date not certain", or a date that
    /// doesn't add up ("You said Saturday the 1st, but…").
    var note: String?
    /// suggested, accepted, done, dismissed
    var status: String
    var conversationID: UUID?
    var created: Date

    init(type: String, title: String, start: Date? = nil, allDay: Bool = false, place: String? = nil, quote: String? = nil,
         status: String = "suggested", conversationID: UUID? = nil) {
        self.id = UUID(); self.type = type; self.title = title; self.start = start; self.allDay = allDay; self.place = place
        self.quote = quote; self.status = status; self.conversationID = conversationID; self.created = Date()
    }
}

/// Something worth knowing beyond the day it was said ("Mum's birthday is 2 November"), picked
/// out of a conversation or added by you: shown in Settings › Things WTF Knows, and given to the
/// AI when it's relevant.
@Model
final class Fact {
    @Attribute(.unique) var id: UUID
    var text: String
    var created: Date
    var conversationID: UUID?

    init(text: String, conversationID: UUID? = nil) {
        self.id = UUID(); self.text = text; self.created = Date(); self.conversationID = conversationID
    }
}

/// A question in Ask, or WTF's answer: kept on the iPhone (see ChatLog).
struct ChatMessage: Identifiable, Equatable, Codable {
    var id = UUID()
    var fromUser: Bool
    var text: String
    var isError = false
    var date = Date()
    /// The conversations it's about (or drew on): deleting one deletes this too.
    var about: [UUID]? = nil
}
