import ActivityKit
import Foundation

/// The Lock Screen / Dynamic Island card while WTF listens: the topic now and the trail that led
/// here, with anything left hanging marked. Shared by the app and its widget extension.
struct ListeningAttributes: ActivityAttributes {
    struct Step: Codable, Hashable {
        var title: String
        var hanging: Bool
        var current: Bool
    }

    struct ContentState: Codable, Hashable {
        /// What's being talked about now, once there's a topic.
        var topic: String?
        /// The last few topics, oldest first.
        var trail: [Step]
        /// Listening since.
        var since: Date
        /// How many topics are left hanging today.
        var hanging: Int
        /// Anything heard to answer "what was I saying?" from: its button shows only once there is.
        var heard = false
        /// A topic before this one to go back to: "Before that" shows only when there is.
        var earlier = false
        /// The answer to the last press of the card's buttons, shown on it for a while: they've
        /// nowhere else to show it.
        var answer: String?
    }
}

extension ListeningAttributes.ContentState {
    /// Read leniently: a card started by an earlier WTF hasn't the newer parts.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        topic = try c.decodeIfPresent(String.self, forKey: .topic)
        trail = try c.decodeIfPresent([ListeningAttributes.Step].self, forKey: .trail) ?? []
        since = try c.decodeIfPresent(Date.self, forKey: .since) ?? Date()
        hanging = try c.decodeIfPresent(Int.self, forKey: .hanging) ?? 0
        heard = try c.decodeIfPresent(Bool.self, forKey: .heard) ?? false
        earlier = try c.decodeIfPresent(Bool.self, forKey: .earlier) ?? false
        answer = try c.decodeIfPresent(String.self, forKey: .answer)
    }
}
