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

    /// The second of the day a line like "[14:03:12] Speech: …" was said at, or nil if it has no time.
    public static func secondOfDay(_ line: Substring) -> Int? {
        guard line.count > 9, line.hasPrefix("["), let h = Int(line.dropFirst(1).prefix(2)), let m = Int(line.dropFirst(4).prefix(2)),
              let s = Int(line.dropFirst(7).prefix(2)) else { return nil }
        return h * 3600 + m * 60 + s
    }

    /// When each of [lines] was said (nil for one with no time): lines only carry the time of
    /// day, so the day comes from [start], the conversation's start, and moves on when the times
    /// go back by more than half a day (a conversation that ran past midnight).
    public static func times(of lines: [Substring], from start: Date, calendar: Calendar = .current) -> [Date?] {
        var day = calendar.startOfDay(for: start)
        var last = start
        return lines.map { line in
            guard let second = secondOfDay(line) else { return nil }
            var t = day.addingTimeInterval(Double(second))
            if t < last.addingTimeInterval(-12 * 3600) {
                day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
                t = day.addingTimeInterval(Double(second))
            }
            last = t
            return t
        }
    }

    /// [text], a recording's lines that began at [at], put into [transcript] where they belong in
    /// time: usually at the end, but a recording that's transcribed late (a retry) goes back
    /// among the lines said around it, not after newer ones.
    public static func insert(_ text: String, at: Date, into transcript: String, from start: Date, calendar: Calendar = .current) -> String {
        guard !text.isEmpty else { return transcript }
        guard !transcript.isEmpty else { return text }
        let lines = transcript.split(separator: "\n")
        let times = Self.times(of: lines, from: start, calendar: calendar)
        guard let i = times.firstIndex(where: { ($0 ?? .distantPast) > at }) else { return transcript + "\n" + text }
        return (Array(lines[..<i]) + [Substring(text)] + Array(lines[i...])).joined(separator: "\n")
    }

    /// Short as possible for the AI: no times, one line per turn. Without voices, just the words.
    public static func compact(_ transcript: String) -> String {
        // A gap marker ("(…)", "(…earlier part left out…)") is kept as it is, with no voice: the
        // AI's told something's missing there, rather than reading the two sides as one.
        var turns: [(String, String)] = []
        for raw in transcript.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if isGap(line) {
                turns.append(("", line))
                continue
            }
            guard let g = turn.whole(line) else { continue }
            if let last = turns.last, last.0 == g[1] { turns[turns.count - 1].1 += " " + g[2] } else { turns.append((g[1], g[2])) }
        }
        if Set(turns.map(\.0).filter { !$0.isEmpty }) == ["Speech"] { return turns.map(\.1).joined(separator: "\n") }
        return turns.map { $0.0.isEmpty ? $0.1 : "\($0.0): \($0.1)" }.joined(separator: "\n")
    }

    /// A line marking words left out: "(…)" or "(…earlier part left out…)".
    static func isGap(_ line: String) -> Bool {
        line.hasPrefix("(") && line.hasSuffix(")") && line.contains("\u{2026}")
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
