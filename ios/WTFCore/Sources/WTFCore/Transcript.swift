import Foundation

/// A stretch of transcribed speech.
public struct Utterance: Equatable, Sendable {
    public var start: Date
    /// "You", "Speaker 2", or "Speech" when voices aren't told apart.
    public var speaker: String
    public var text: String
    public init(start: Date, speaker: String, text: String) { self.start = start; self.speaker = speaker; self.text = text }
}

public enum TranscriptFormat {
    /// Lines like "[14:03:12] Speech: text", consecutive lines from the same voice joined.
    public static func lines(_ utterances: [Utterance], calendar: Calendar = .current) -> String {
        var kept: [Utterance] = []
        for u in utterances where !u.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if var last = kept.last, last.speaker == u.speaker {
                last.text = last.text.trimmingCharacters(in: .whitespaces) + " " + u.text.trimmingCharacters(in: .whitespaces)
                kept[kept.count - 1] = last
            } else {
                kept.append(u)
            }
        }
        return kept.map { u in
            let c = calendar.dateComponents([.hour, .minute, .second], from: u.start)
            return String(format: "[%02d:%02d:%02d] ", c.hour!, c.minute!, c.second!) + "\(u.speaker): \(u.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }

    public static let turn = Rx(#"^\[[^\]]*] ([^:]+): (.*)$"#)

    /// Short as possible for the AI: no times, one line per turn. Without voices, just the words.
    public static func compact(_ transcript: String) -> String {
        var turns: [(String, String)] = []
        for raw in transcript.split(separator: "\n") {
            guard let g = turn.whole(raw.trimmingCharacters(in: .whitespaces)) else { continue }
            if let last = turns.last, last.0 == g[1] { turns[turns.count - 1].1 += " " + g[2] } else { turns.append((g[1], g[2])) }
        }
        if Set(turns.map(\.0)) == ["Speech"] { return turns.map(\.1).joined(separator: "\n") }
        return turns.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// Whisper-style tidying for any recogniser: stray quotes and repeated sentences.
    public static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\"", with: "")
        // The recogniser marks hesitations "#um", "#oh": not words anyone wants to read back.
        t = Rx(#"\s*#\w+[,.]?"#).replace(t, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sentences = Rx(#"(?<=[.?!])\s+"#).split(t)
        var out: [String] = []
        for s in sentences where out.last?.lowercased() != s.lowercased() { out.append(s) }
        t = out.joined(separator: " ")
        return t
    }
}

/// Answers "what do I need to buy?" and the like straight from the list: exact and instant.
public enum ListAnswers {
    public struct Item: Sendable {
        public var type: ActionType, title: String, start: Date?, allDay: Bool, place: String?
        public init(type: ActionType, title: String, start: Date? = nil, allDay: Bool = false, place: String? = nil) {
            self.type = type; self.title = title; self.start = start; self.allDay = allDay; self.place = place
        }
    }

    static let shopping = Rx(#"\b(buy|shopping|groceries|shops|supermarket|pick up|get from the shop)\b"#)
    static let events = Rx(#"\b(appointments?|calendar|meetings?|what'?s on|plans|schedule|diary|booked)\b"#)
    static let todos = Rx(#"\b(to-?dos?|tasks|need to do|have to do|promised|promise)\b"#)

    public static func answer(_ question: String, open: [Item], now: Date = Date()) -> String? {
        let q = question.lowercased()
        // Only clear list questions; anything about the past goes to the AI.
        if Rx(#"\b(was|were|said|saying|earlier|yesterday|did|tell|told|decide|decided|happen|happened|who|why|talk|talked|discuss|discussed)\b"#).test(q) { return nil }
        func list(_ items: [Item], _ empty: String, _ header: String) -> String {
            items.isEmpty ? empty : header + "\n" + items.map { "\u{2022} \($0.title)" }.joined(separator: "\n")
        }
        if shopping.test(q) { return list(open.filter { $0.type == .buy }, "Nothing to buy on your list.", "To buy:") }
        if todos.test(q) { return list(open.filter { $0.type == .todo }, "Nothing on your to-do list.", "Still to do:") }
        if events.test(q) {
            let upcoming = open.filter { $0.type == .event && ($0.start ?? .distantFuture) >= now.addingTimeInterval(-3600) }
                .sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            if upcoming.isEmpty { return "I haven't heard about any upcoming appointments." }
            let f = DateFormatter(); f.dateFormat = "EEE d MMM, HH:mm"
            let d = DateFormatter(); d.dateFormat = "EEE d MMM"
            return "Coming up:\n" + upcoming.map { e in
                "\u{2022} \(e.title): " + (e.start.map { e.allDay ? d.string(from: $0) : f.string(from: $0) } ?? "date not clear") + (e.place.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
        }
        return nil
    }
}
