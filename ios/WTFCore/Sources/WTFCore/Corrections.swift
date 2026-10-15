import Foundation

/// Fixing what the recogniser misheard, from context ("bucked the back room" → "booked the back
/// room", "half free" → "half three"). The AI proposes a corrected line; it's only taken if it
/// changes a few words and leaves the rest exactly as said, so it can't rewrite what you said.
public enum Corrections {
    /// At least this share of the words must be untouched, in order.
    static let keep = 0.8

    /// The lines' words for the AI, numbered: "1. Right, so we need to sort Mum's birthday."
    /// - Parameters:
    ///   - doubts: the words the recogniser wasn't sure of, and its other readings.
    ///   - known: names and words this person uses (people, places, shops, their list).
    ///   - learned: mistakes corrected before ("bucked" → "booked").
    public static func prompt(_ lines: [String], doubts: [Doubt] = [], known: [String] = [], learned: [LearnedFix] = []) -> String {
        let numbered = lines.enumerated().map { "\($0.offset + 1). \(text(of: $0.element))" }.joined(separator: "\n")
        var hints = ""
        if !doubts.isEmpty {
            hints += "The recogniser wasn't sure of these words, so they're the likeliest to be wrong: " + doubts.prefix(25).map { d in
                "\u{201C}\(d.word)\u{201D}" + (d.alternatives.isEmpty ? "" : " (it also heard \(d.alternatives.map { "\u{201C}\($0)\u{201D}" }.joined(separator: " or ")))")
            }.joined(separator: ", ") + ".\n"
        }
        if !known.isEmpty {
            hints += "Names and words this person uses: " + known.prefix(40).joined(separator: ", ") + ".\n"
        }
        if !learned.isEmpty {
            hints += "Words it has misheard for them before: " + learned.prefix(15).map { "\u{201C}\($0.heard)\u{201D} for \u{201C}\($0.meant)\u{201D}" }.joined(separator: ", ") + ".\n"
        }
        return """
            These lines were written down by speech recognition, which sometimes mishears a word: "bucked the back \
            room" for "booked the back room", "half free" for "half three", "scar" for "scarf", "double a" for "AA". \
            Using the context, fix only words that were clearly misheard. Keep everything else exactly as it is: \
            the same words in the same order, no rephrasing, nothing added or left out. Give back every line, \
            numbered as here, even if it needs no change.
            \(hints.isEmpty ? "" : "\n" + hints)
            \(numbered)
            """
    }

    /// [original] lines with the AI's [corrected] texts put in where they pass the checks.
    /// [protected]: words the recogniser was sure of, which a fix may not change.
    public static func apply(_ corrected: [String], to original: [String], protected: Set<String> = []) -> [String] {
        original.enumerated().map { i, line in
            guard i < corrected.count else { return line }
            let fixed = unnumbered(corrected[i], number: i + 1)
            guard accept(fixed, for: text(of: line), protected: protected) else { return line }
            return prefix(of: line) + fixed
        }
    }

    /// A small fix, not a rewrite: most words the same, in the same order, about the same length,
    /// and none of the words the recogniser was sure of changed.
    public static func accept(_ fixed: String, for original: String, protected: Set<String> = []) -> Bool {
        let a = words(original), b = words(fixed)
        guard !b.isEmpty, a != b else { return false }
        guard abs(a.count - b.count) <= max(2, a.count / 10) else { return false }
        guard Double(commonInOrder(a, b)) / Double(max(a.count, b.count)) >= keep else { return false }
        if !protected.isEmpty {
            let changed = WordDiff.stretches(a, b).flatMap(\.removed)
            guard !changed.contains(where: { protected.contains(Doubts.normal($0)) }) else { return false }
        }
        return true
    }

    /// The changes a fix made, for remembering ("bucked" → "booked").
    public static func changes(from original: [String], to fixed: [String]) -> [(heard: String, meant: String)] {
        zip(original, fixed).flatMap { a, b in a == b ? [] : Fixes.pairs(from: text(of: a), to: text(of: b)) }
    }

    static func words(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).map { $0.trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
    }

    /// The longest run of words both share, in order (LCS).
    static func commonInOrder(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let above = row[j]
                row[j] = x == b[j - 1] ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// The line without the number the AI was given it under ([number]), however it wrote it
    /// back: "1. Right", "1) Right", "[1] Right", "(1) Right", "1: Right" all give "Right". Only
    /// that number, and not a time: line 10 saying "10:30 works" keeps its 10:30.
    public static func unnumbered(_ line: String, number: Int) -> String {
        let n = String(number)
        let numbering = Rx(#"^\s*(?:\[\s*"# + n + #"\s*\]|\(\s*"# + n + #"\s*\)|"# + n + #"\s*(?:[)\]-]|[.:](?!\d)))\s*"#)
        return numbering.replace(line, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A transcript with the "[1] " a correction once left at the start of a line's words taken
    /// out again ("[14:04:10] Speaker 1: [1] Right, so…" → "[14:04:10] Speaker 1: Right, so…").
    public static func repaired(_ transcript: String) -> String {
        transcript.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            let l = String(line)
            let words = text(of: l)
            guard words != l, let m = Rx(#"^\[\s*\d+\s*\]\s*"#).first(words) else { return l }
            return prefix(of: l) + String(words.dropFirst(m[0].count))
        }.joined(separator: "\n")
    }

    /// "[13:16:00] Speaker 1: " and the words after it.
    public static func prefix(of line: String) -> String {
        guard let g = TranscriptFormat.turn.whole(line) else { return "" }
        return String(line.dropLast(g[2].count))
    }

    public static func text(of line: String) -> String {
        TranscriptFormat.turn.whole(line)?[2] ?? line
    }
}
