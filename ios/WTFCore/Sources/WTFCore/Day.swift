import Foundation

/// One conversation as a day's review sees it: its notes, not its words (a whole day's words
/// wouldn't fit in what the on-device model can read at once).
public struct DayNote: Sendable, Equatable {
    public var start: Date
    public var title: String
    /// Its summary's points.
    public var points: [String]
    public var decided: [String]
    public var todo: [String]
    /// Dropped part-way ("The MOT: you were saying…") or left unanswered.
    public var hanging: [String]

    public init(start: Date, title: String, points: [String] = [], decided: [String] = [], todo: [String] = [], hanging: [String] = []) {
        self.start = start; self.title = title; self.points = points; self.decided = decided; self.todo = todo; self.hanging = hanging
    }
}

/// A day looked back on: what was talked about, what got settled, what's still to do and what
/// was left hanging, across all its conversations.
public enum DayReview {
    /// Each note once across the day (the same thing noted in two conversations is one), with
    /// the conversation it's from (its index in [notes]); at most [limit].
    public static func gather(_ notes: [DayNote], limit: Int = 12, _ pick: (DayNote) -> [String]) -> [(text: String, from: Int)] {
        var seen = Set<String>()
        var out: [(text: String, from: Int)] = []
        for (i, note) in notes.enumerated() {
            for raw in pick(note) {
                let text = tidy(raw)
                let key = squash(text)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                out.append((text: text, from: i))
                if out.count == limit { return out }
            }
        }
        return out
    }

    /// "• you: ring the garage" → "Ring the garage".
    public static func tidy(_ note: String) -> String {
        var t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        for bullet in ["\u{2022}", "-", "*"] where t.hasPrefix(bullet) {
            t = String(t.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
        }
        if t.lowercased().hasPrefix("you:") { t = String(t.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        guard let first = t.first else { return t }
        return first.uppercased() + t.dropFirst()
    }

    /// Letters and digits only, in lower case: for spotting the same note twice.
    static func squash(_ s: String) -> String { String(s.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// Without Apple Intelligence: how many conversations, when, and what about.
    public static func plain(_ notes: [DayNote], time: (Date) -> String) -> String {
        let sorted = notes.sorted { $0.start < $1.start }
        guard let first = sorted.first, let last = sorted.last else { return "Nothing was heard." }
        let titles = sorted.map(\.title).filter { !$0.isEmpty } // untitled: still being written up
        let about = titles.isEmpty ? "" : ": " + titles.prefix(4).joined(separator: ", ") + (titles.count > 4 ? " and \(titles.count - 4) more" : "")
        if sorted.count == 1 { return "One conversation, at \(time(first.start))\(about)." }
        return "\(sorted.count) conversations, between \(time(first.start)) and \(time(last.start))\(about)."
    }
}

extension Prompts {
    /// For "Your Day": a short look back over a day, from its conversations' notes. Every
    /// conversation is named (the latest, if even that's too much); then their details, a line
    /// from each in turn, while they fit in [budget] tokens. [today]: it isn't over yet.
    public static func day(_ notes: [DayNote], today: Bool, budget: Int = 1_800) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        var sorted = notes.sorted { $0.start < $1.start }
        var heads = sorted.map { "\(f.string(from: $0.start)) \($0.title)" }
        var used = heads.reduce(0) { $0 + tokens($1) }
        var earlier = 0
        while used > budget, heads.count > 1 {
            used -= tokens(heads.removeFirst())
            sorted.removeFirst()
            earlier += 1
        }
        var blocks = heads.map { [$0] }
        // What was settled first, then what's to do, what was left hanging, and the rest.
        var queues = sorted.map { n in
            n.decided.map { "Decided: " + DayReview.tidy($0) } + n.todo.map { "To do: " + DayReview.tidy($0) }
                + n.hanging.map { "Left hanging: " + DayReview.tidy($0) } + n.points.map { "- " + DayReview.tidy($0) }
        }
        while queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where !queues[i].isEmpty {
                let line = "  " + queues[i].removeFirst()
                guard used + tokens(line) <= budget else { continue }
                blocks[i].append(line)
                used += tokens(line)
            }
        }
        let body = (earlier > 0 ? ["(\(earlier) earlier conversation\(earlier == 1 ? "" : "s") left out)"] : [])
            + blocks.map { $0.joined(separator: "\n") }
        return """
            Notes on the conversations I had \(today ? "today so far" : "that day"), in order, each with its time:
            \(body.joined(separator: "\n"))

            In 2 or 3 short sentences, recap \(today ? "my day so far" : "that day") for me: what it was mostly about, \
            what got settled, and what's still to do or was left unfinished. Talk to me as "you". Use only what's in the notes.
            """
    }
}
