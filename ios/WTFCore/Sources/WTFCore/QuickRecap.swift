import Foundation

/// "WTF?" answered straight away, with no AI: what was being said, word for word, and who cut in.
/// Ready the moment the latest speech is transcribed, so it comes first; the AI's gist follows.
/// (Ported from the Android app.) Lines look like "[11:40:02] You: …"; with no voices to tell
/// apart (iPhone), every line says "Speech".
public enum QuickRecap {
    static let line = Rx(#"^\[(\d\d):(\d\d)(?::(\d\d))?] ([^:]+): (.*)$"#)
    static let owner = Rx(#"^\[[^\]]*] You: "#, caseSensitive: true)

    struct Turn {
        var at: Date, who: String, text: String
        var words: Int { text.split(separator: " ").count }
        var cutOff: Bool { text.trimmingCharacters(in: .whitespaces).last.map { !".?!…".contains($0) } ?? false }
    }

    /// The conversation as turns (one voice's lines joined), whether your voice is known, and
    /// whether voices are told apart at all.
    static func parse(_ transcript: String, start: Date, calendar: Calendar) -> (turns: [Turn], ownerKnown: Bool, anonymous: Bool) {
        let ownerKnown = transcript.split(separator: "\n").contains { owner.test(String($0)) }
        let voices = Set(transcript.split(separator: "\n").compactMap { line.whole(String($0))?[4] })
        let anonymous = voices == ["Speech"]
        var turns: [Turn] = []
        let startParts = calendar.dateComponents([.year, .month, .day], from: start)
        for raw in transcript.split(separator: "\n") {
            guard let g = line.whole(raw.trimmingCharacters(in: .whitespaces)), !g[5].isEmpty else { continue }
            var parts = startParts
            parts.hour = Int(g[1]); parts.minute = Int(g[2]); parts.second = Int(g[3]) ?? 0
            var at = calendar.date(from: parts)!
            if at < start.addingTimeInterval(-60) { at = calendar.date(byAdding: .day, value: 1, to: at)! } // went past midnight
            if let last = turns.last, last.who == g[4] {
                turns[turns.count - 1] = Turn(at: at, who: g[4], text: last.text + " " + g[5])
            } else {
                turns.append(Turn(at: at, who: g[4], text: g[5]))
            }
        }
        return (turns, ownerKnown, anonymous)
    }

    /// The thread you lost: a sentence that broke off, else the last real say (yours, if known).
    static func pick(_ turns: [Turn], ownerKnown: Bool) -> Int? {
        let recent = max(0, turns.count - 12)
        func mine(_ i: Int) -> Bool { !ownerKnown || turns[i].who == Labels.me }
        func find(_ test: (Turn) -> Bool) -> Int? {
            guard !turns.isEmpty else { return nil }
            return stride(from: turns.count - 1, through: recent, by: -1).first { mine($0) && test(turns[$0]) }
        }
        return find({ $0.cutOff && $0.words >= 4 }) ?? find({ $0.words >= 6 }) ?? find({ _ in true })
    }

    /// The same, short enough to be read out in your ear (Siri, AirPods).
    public static func spoken(_ transcript: String, start: Date, now: Date, calendar: Calendar = .current) -> String? {
        let (turns, ownerKnown, anonymous) = parse(transcript, start: start, calendar: calendar)
        guard let i = pick(turns, ownerKnown: ownerKnown) else { return nil }
        let main = turns[i]
        let said = ago(main.at, now: now, calendar: calendar)
        let words = main.text.split(separator: " ")
        var quote = words.suffix(30).joined(separator: " ")
        if words.count > 30 { quote = "\u{2026}" + quote }
        var out: String
        if anonymous {
            out = "The last thing said, \(said), was: \(quote)"
        } else if ownerKnown {
            out = "You were saying, \(said): \(quote)"
        } else {
            out = "\(main.who) was saying, \(said): \(quote)"
        }
        if main.cutOff { out += "\u{2026}" }
        if !anonymous, i + 1 < turns.count {
            let who = turns[i + 1].who == Labels.me ? "you" : name(turns[i + 1].who)
            out += main.cutOff ? " Then \(who) cut in." : " Then \(who) said something."
        }
        return out
    }

    /// - Parameters:
    ///   - transcript: a conversation's lines.
    ///   - start: when it began (lines only carry the time of day).
    public static func of(_ transcript: String, start: Date, now: Date, calendar: Calendar = .current) -> String? {
        let (turns, ownerKnown, anonymous) = parse(transcript, start: start, calendar: calendar)
        guard let i = pick(turns, ownerKnown: ownerKnown) else { return nil }
        let main = turns[i]
        let said = ago(main.at, now: now, calendar: calendar)
        var out: String
        if anonymous {
            out = said.hasPrefix("at ") ? "At \(said.dropFirst(3)), the last thing said was:" : "Last thing said, \(said):"
        } else {
            let who = ownerKnown ? "you" : name(main.who)
            let verb = ownerKnown ? "were" : "was"
            out = said.hasPrefix("at ") ? "At \(said.dropFirst(3)) \(who) \(verb) saying:" : "\(who.prefix(1).uppercased() + who.dropFirst()) \(verb) saying, \(said):"
        }
        out += "\n\u{201C}\(quote(main.text))\u{201D}"
        if !anonymous {
            if i + 1 < turns.count {
                let after = turns[i + 1]
                out += "\n\nThen \(name(after.who)) \(main.cutOff ? "cut in" : "said"): \u{201C}\(quote(after.text, max: 120))\u{201D}"
            } else if i > 0 {
                let before = turns[i - 1]
                out += "\n\nJust before, \(name(before.who)) said: \u{201C}\(quote(before.text, max: 120))\u{201D}"
            }
            if !ownerKnown { out += "\n\nTap your name in a transcript and choose That\u{2019}s Me, and WTF will know which voice is yours." }
        }
        return out
    }

    /// A line's speaker as said aloud: "Speech" (voices not told apart then) is just "someone".
    static func name(_ who: String) -> String { who == Labels.anonymous ? "someone" : who }

    /// "just now", "40 seconds ago", "5 minutes ago", or "at 11:40".
    static func ago(_ at: Date, now: Date, calendar: Calendar) -> String {
        let s = max(0, Int(now.timeIntervalSince(at)))
        switch s {
        case ..<15: return "just now"
        case ..<60: return "\(s) seconds ago"
        case ..<120: return "a minute ago"
        case ..<3600: return "\(s / 60) minutes ago"
        default:
            let c = calendar.dateComponents([.hour, .minute], from: at)
            let time = String(format: "at %02d:%02d", c.hour!, c.minute!)
            // Not today: which day, so yesterday's isn't taken for just now.
            if calendar.isDate(at, inSameDayAs: now) { return time }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(at, inSameDayAs: yesterday) { return "yesterday " + time }
            let f = DateFormatter(); f.calendar = calendar; f.locale = Locale(identifier: "en_GB"); f.dateFormat = "EEEE d MMMM"
            return "on \(f.string(from: at)) " + time
        }
    }

    /// The end of what was said (that's where the thread broke), at most about [max] characters.
    public static func quote(_ text: String, max: Int = 200) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        let broke = t.last.map { !".?!…".contains($0) } ?? false
        var s = t
        if s.count > max {
            var kept: [String] = []
            var length = 0
            for sentence in Rx(#"(?<=[.?!])\s+"#).split(s).reversed() {
                if !kept.isEmpty && length + sentence.count + 1 > max { break }
                kept.insert(sentence, at: 0)
                length += sentence.count + 1
            }
            s = kept.joined(separator: " ")
            if s.count > max {
                let tail = String(s.suffix(max))
                s = tail.firstIndex(of: " ").map { String(tail[tail.index(after: $0)...]) } ?? tail
            }
            s = "\u{2026}" + s
        }
        return broke ? s + "\u{2026}" : s
    }
}
