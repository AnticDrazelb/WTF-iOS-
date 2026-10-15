import Foundation

/// What a question is after: decides which transcript the AI reads.
public enum RecallIntent: Equatable, Sendable { case latest, digest, commitments, focused }

/// Builds prompts for Apple's on-device model, whose context is small (4,096 tokens), so it's
/// given only what the question needs. (A short version of the Android app's LocalRecall.)
public enum Prompts {
    static let commitment = Rx(#"promis|said i'?d|i said i would|to-?do|commit|agreed to|supposed to|\bowe\b|need to do|have to do"#)
    static let digest = Rx(#"summar|recap|my day|overview|what did i do|what have i (done|been doing)|everything"#)
    static let latest = Rx(#"\bjust\b|a (minute|moment|sec|second)s? ago|right now|where was i|lost (my|the) (train|thread)|interrupted|on about|what was i (just )?(saying|talking|on)|where were we|what were we (just )?(saying|talking|on)|remind me what (i|we) (was|were) (saying|talking)|last thing (i|we) said"#)
    static let timeWords = Rx(#"\b(yesterday|this morning|last night|earlier|today|afternoon|evening|lunch|hours? ago)\b"#)

    public static func intent(_ question: String) -> RecallIntent {
        let q = question.lowercased()
        if commitment.test(q) { return .commitments }
        if digest.test(q) { return .digest }
        if latest.test(q) && !timeWords.test(q) { return .latest }
        return .focused
    }

    /// Roughly 4 characters a token in English.
    public static func tokens(_ s: String) -> Int { s.count / 4 + 1 }

    /// The last lines of [transcript] that fit in [budget] tokens, oldest first. If even the
    /// newest line is too long (one person talking for minutes), the end of it.
    public static func tail(_ transcript: String, budget: Int) -> String {
        let lines = transcript.split(separator: "\n").map(String.init)
        var kept: [String] = []
        var used = 0
        var cut = false
        for line in lines.reversed() {
            let t = tokens(line) + 1
            if used + t > budget {
                cut = true
                if kept.isEmpty { kept = [end(of: line, budget: budget)] }
                break
            }
            kept.insert(line, at: 0)
            used += t
        }
        return (cut ? "(\u{2026}earlier part left out\u{2026})\n" : "") + kept.joined(separator: "\n")
    }

    /// The last [budget] tokens' worth of a line, keeping who said it ("You: …the end of it").
    static func end(of line: String, budget: Int) -> String {
        var label = ""
        var text = Substring(line)
        if let colon = line.range(of: ": "), line.distance(from: line.startIndex, to: colon.lowerBound) <= 45 {
            label = String(line[..<colon.upperBound])
            text = line[colon.upperBound...]
        }
        let room = max(40, (budget - tokens(label) - 2) * 4)
        guard text.count > room else { return line }
        var kept = text.suffix(room)
        // Start at a word.
        if let space = kept.firstIndex(of: " ") { kept = kept[kept.index(after: space)...] }
        return label + "\u{2026}" + kept
    }

    public static let instructions = """
        You are WTF, a memory aid for someone who goes off on tangents and loses their train of thought. \
        Their phone records their day and transcribes it. In transcripts, lines marked "You" are theirs; other \
        voices are numbered ("Speaker 2") or named. Answer straight away, with no lead-in like "Sure" or \
        "Here's a summary", briefly and plainly, and talk to them as "you". Call people by their names if you \
        know them, otherwise "the other person" or "someone"; never write "Speaker 1" or "Speaker 2". \
        Use only what you're given, exactly as it was said: add nothing, don't assume anything was booked, \
        decided or agreed unless someone said so, and keep numbers as they were said ("turned five" is an \
        age, not a date). If what you're given doesn't answer the question, say so. Don't mention the current \
        date or time unless asked.
        """

    /// "What was I just on about?": only the last few minutes of the latest conversation.
    public static func latest(question: String, transcript: String, topic: String?, now: Date, background: String = "", start: Date? = nil) -> String {
        """
        \(background)The most recent conversation\(topic.map { " (topic: \($0))" } ?? ""), in order, oldest first, each line with the time it was said; the last line is the most recent:
        \(tail(TranscriptFormat.compact(transcript), budget: background.isEmpty ? 900 : 700))

        (It's \(clock(now)) now.\(when(start, now: now))) In 2 or 3 sentences, tell me what I was just talking about. If my last words trail off \
        unfinished, say what I was in the middle of saying. Only say I was interrupted if someone else spoke after me.
        My question: \(question)
        """
    }

    /// The same, for reading aloud in your ear: one or two short sentences, no lists.
    public static func spoken(transcript: String, topic: String?, leftAt: String?, now: Date, background: String = "", start: Date? = nil) -> String {
        """
        \(background)The most recent conversation\(topic.map { " (topic: \($0))" } ?? ""), oldest first; the last line is the most recent:
        \(tail(TranscriptFormat.compact(transcript), budget: background.isEmpty ? 700 : 550))
        \(leftAt.map { "\nEarlier, I dropped a topic part-way: \($0)\n" } ?? "")
        (It's \(clock(now)) now.\(when(start, now: now))) In one or two short sentences that will be read aloud to me, say what I was just \
        talking about and, if I trailed off, what I was in the middle of saying. No lists, no quotation marks.
        """
    }

    /// "Where was I with ...?": one topic from the trail, and the talk around it.
    public static func thread(_ title: String, leftAt: String?, lines: String) -> String {
        """
        In a conversation, this topic came up: \(title). What was said around then, oldest first:
        \(tail(TranscriptFormat.compact(lines), budget: 1_200))
        \(leftAt.flatMap { $0.isEmpty ? nil : "\nIt seems I dropped it part-way: \($0)\n" } ?? "")
        In one or two sentences, remind me where I'd got to with \(title), and if I trailed off, what I was about \
        to say. Only use what's above; if it barely comes up, say so.
        """
    }

    /// The sentences in [lines] that mention [topic]'s words, for when there's no AI.
    public static func sentences(about topic: String, in lines: String, limit: Int = 3) -> [String] {
        let keys = keywords(topic).map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
        guard !keys.isEmpty else { return [] }
        let text = TranscriptFormat.compact(lines).replacingOccurrences(of: "\n", with: " ")
        return Rx(#"(?<=[.?!])\s+"#).split(text).filter { s in
            let l = s.lowercased()
            return keys.contains { l.contains($0) }
        }.prefix(limit).map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Any other question: titles and summaries of the day, plus the best-matching transcript.
    public static func focused(question: String, notes: [(label: String, title: String?, summary: String?)], best: (label: String, transcript: String)?, now: Date, background: String = "") -> String {
        var body = background + (notes.count == 1 ? "The conversation:\n" : "Conversations recorded on my phone:\n")
        for n in notes.prefix(12) {
            body += "- \(n.label): \(n.title ?? "untitled")" + (n.summary.map { "\n  " + $0.replacingOccurrences(of: "\n", with: "\n  ") } ?? "") + "\n"
        }
        if let best { body += "\nFrom the transcript of \(best.label):\n" + tail(TranscriptFormat.compact(best.transcript), budget: background.isEmpty ? 1_600 : 1_300) + "\n" }
        let which = notes.count > 1 ? ", saying which conversation (its time) you mean" : ""
        return body + "\n(It's \(clock(now)) now.) Answer my question in 2 to 4 short sentences\(which).\nMy question: \(question)"
    }

    /// An answer as the user should see (or hear) it: without the lead-in small models add
    /// ("Okay, so here's a summary of the conversation."), and without them telling the time back
    /// ("It is now Wednesday, 2:06pm.").
    public static func tidy(_ answer: String) -> String {
        var t = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        var before = ""
        while before != t {
            before = t
            t = leadIn.replace(t, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t = tellingTheTime.replace(t, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        t = Rx(#"\n{3,}"#).replace(t, with: "\n\n")
        guard let first = t.first, first.isLowercase else { return t }
        return first.uppercased() + t.dropFirst()
    }
    static let leadIn = Rx(
        #"^(?:(?:sure|okay|ok|alright|all right|certainly|of course|absolutely|got it)\b[,!.]?\s*(?:so\b,?\s*)?|"# +
        #"(?:here'?s|here is|this is)\s+(?:a|an|the|your|my)?\s*(?:quick|short|brief)?\s*(?:summary|recap|rundown|overview|answer)\b[^:\n]*?(?::|\.(?=\s|$))\s*|"# +
        #"(?:based on|according to|looking at)\s+(?:the|your|my)\s+(?:notes|transcripts?|conversations?)\b[^,\n]*,\s*)"#)
    static let tellingTheTime = Rx(#"(?:^|(?<=[.!?\n]))\s*(?:it'?s|it is)\s+(?:now|currently)\s+(?:about\s+|around\s+|just\s+)?(?:monday|tuesday|wednesday|thursday|friday|saturday|sunday|\d{1,2}[:.]\d\d|\d{1,2}\s*(?:am|pm)|(?:the\s+)?\d{1,2}(?:st|nd|rd|th))[^.!?\n]*[.!?]?"#)

    /// Keywords for finding the right conversation.
    public static func keywords(_ question: String) -> [String] {
        let stop: Set<String> = ["the", "and", "was", "were", "what", "when", "where", "who", "why", "how", "did", "does", "about", "with",
                                 "that", "this", "they", "them", "said", "say", "tell", "remind", "remember", "earlier", "today",
                                 "yesterday", "just", "you", "your", "have", "had", "has", "been", "talking", "saying", "conversation"]
        var seen = Set<String>()
        return Rx(#"[A-Za-z][A-Za-z']+"#).all(question).map { $0[0].lowercased() }
            .filter { $0.count >= 3 && !stop.contains($0) && seen.insert($0).inserted }
    }

    /// " That conversation was yesterday." when it wasn't today, so it isn't called "just now".
    static func when(_ start: Date?, now: Date) -> String {
        guard let start, !Calendar.current.isDate(start, inSameDayAs: now) else { return "" }
        if let y = Calendar.current.date(byAdding: .day, value: -1, to: now), Calendar.current.isDate(start, inSameDayAs: y) {
            return " That conversation was yesterday, so say so rather than \"just\"."
        }
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        return " That conversation was on \(f.string(from: start)), so say when rather than \"just\"."
    }

    static func clock(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE HH:mm"
        return f.string(from: d)
    }

    /// For summarising: the conversation as compact as it goes, cut to fit.
    public static func summary(transcript: String, background: String = "") -> String {
        background + "Summarise this conversation from my day. Say what was decided and what was only suggested or still needs doing " +
            "(a plan that has to be confirmed isn't booked). Keep each detail with what it was about: don't connect things " +
            "that weren't connected (if batteries are for the remote, they aren't for a present).\n\n" + tail(TranscriptFormat.compact(transcript), budget: background.isEmpty ? 2_400 : 2_000)
    }

    /// For finding things to act on.
    public static func actions(lines: [String], conversationStart: Date, background: String = "") -> String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        let said = tail(lines.joined(separator: "\n"), budget: background.isEmpty ? 1_800 : 1_400)
        return background + """
            Lines from a conversation recorded on \(f.string(from: conversationStart)). Find appointments (with when they are, \
            in the words used), things to buy (one per item), and things someone said they would do. Be strict: an \
            appointment needs a day or a time actually said for it (never assume today), and say whether it was actually \
            booked or only suggested; things to buy are shopping (groceries, household things), not meals out or \
            takeaways, and never people ("pick up Ezra from school" is collecting him, not shopping); a film, a show or a \
            topic mentioned in passing is none of these. Only what was actually said, in its words: add no tasks of your \
            own; leave a list empty if there's nothing for it.

            \(said)
            """
    }

    /// Facts from a conversation worth keeping after today.
    public static func lastingFacts(transcript: String, known: [String]) -> String {
        """
        A conversation recorded on my phone (lines marked "You" are mine):
        \(tail(TranscriptFormat.compact(transcript), budget: 2_000))
        \(known.isEmpty ? "" : "\nAlready known, don't repeat:\n" + known.prefix(15).map { "- " + $0 }.joined(separator: "\n") + "\n")
        List facts from it worth remembering after today: birthdays and other dates, who people are (names, \
        relationships, jobs), where people live or work, likes and dislikes, and plans with a date. Not passing \
        chatter. Each fact a short sentence that makes sense on its own, e.g. "Mum's birthday is 2 November". \
        Leave the list empty if nothing lasting was said.
        """
    }
}
