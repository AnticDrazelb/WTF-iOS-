import Foundation

/// A word the recogniser wasn't sure of, and what else it thought it might have been.
public struct Doubt: Codable, Equatable, Sendable {
    public var word: String
    public var confidence: Double?
    public var alternatives: [String]
    public init(word: String, confidence: Double?, alternatives: [String] = []) {
        self.word = word; self.confidence = confidence; self.alternatives = alternatives
    }
}

/// What the recogniser doubted, so fixing misheard words starts where it was unsure and leaves
/// alone what it was sure of. Apple's recogniser gives each word a confidence (0–1) and each
/// phrase its runner-up readings.
public enum Doubts {
    /// Below this, a word is one the recogniser wasn't sure of: pointed out to the AI.
    public static let unsure = 0.6
    /// At or above this, a word is one it was sure of: a correction may not change it.
    public static let sure = 0.9

    /// A word as compared: lower case, no punctuation or spaces round it, straight apostrophes.
    public static func normal(_ w: String) -> String {
        w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines))
    }

    /// The words worth a second look: low confidence, or the recogniser had another reading.
    public static func of(_ words: [SpeakerAlign.Word], limit: Int = 25) -> [Doubt] {
        var out: [Doubt] = []
        var seen = Set<String>()
        for w in words {
            let n = normal(w.text)
            guard !n.isEmpty else { continue }
            let alternatives = w.alternatives.map(normal).filter { !$0.isEmpty && $0 != n }
            guard (w.confidence ?? 1) < unsure || !alternatives.isEmpty, seen.insert(n).inserted else { continue }
            out.append(Doubt(word: n, confidence: w.confidence, alternatives: Array(alternatives.prefix(3))))
        }
        // The least sure first, if there are too many to mention.
        return Array(out.sorted { ($0.confidence ?? 1) < ($1.confidence ?? 1) }.prefix(limit))
    }

    /// Words the recogniser was sure of every time it heard them: corrections leave them be.
    /// Empty when it gave no confidences (then nothing is protected, as before).
    public static func protected(_ words: [SpeakerAlign.Word]) -> Set<String> {
        var sure = Set<String>(), unsureOf = Set<String>()
        for w in words {
            guard let c = w.confidence else { continue }
            let n = normal(w.text)
            guard !n.isEmpty else { continue }
            if c >= Self.sure && w.alternatives.isEmpty { sure.insert(n) } else { unsureOf.insert(n) }
        }
        return sure.subtracting(unsureOf)
    }

    /// For each word of [top] (the recogniser's best reading), what its other readings say
    /// instead where they differ by a single word (replaced by one or two): index → readings.
    public static func alternatives(top: [String], others: [[String]]) -> [Int: [String]] {
        var out: [Int: [String]] = [:]
        let t = top.map(normal)
        for other in others {
            let o = other.map(normal).filter { !$0.isEmpty }
            guard o != t.filter({ !$0.isEmpty }) else { continue }
            for stretch in WordDiff.stretches(t, o) where stretch.removed.count == 1 && (1...2).contains(stretch.inserted.count) {
                let reading = stretch.inserted.joined(separator: " ")
                if !(out[stretch.at]?.contains(reading) ?? false) { out[stretch.at, default: []].append(reading) }
            }
        }
        return out
    }

    /// How sure the recogniser was across some words: for the log, to see how it does on the phone.
    public static func summary(_ words: [SpeakerAlign.Word]) -> String {
        let c = words.compactMap(\.confidence).sorted()
        guard !c.isEmpty else { return "no confidences" }
        let unsureCount = c.filter { $0 < unsure }.count
        return String(format: "%d unsure, lowest %.2f, median %.2f", unsureCount, c[0], c[c.count / 2])
    }
}

/// Where two runs of words differ, word for word (longest common subsequence).
public enum WordDiff {
    public struct Stretch: Equatable, Sendable {
        /// Index in the first run where it starts.
        public var at: Int
        public var removed: [String]
        public var inserted: [String]
    }

    public static func stretches(_ a: [String], _ b: [String]) -> [Stretch] {
        let n = a.count, m = b.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }
        var out: [Stretch] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] { i += 1; j += 1; continue }
            var stretch = Stretch(at: i, removed: [], inserted: [])
            while (i < n || j < m) && !(i < n && j < m && a[i] == b[j]) {
                if j < m && (i == n || dp[i][j + 1] >= dp[i + 1][j]) {
                    stretch.inserted.append(b[j]); j += 1
                } else {
                    stretch.removed.append(a[i]); i += 1
                }
            }
            out.append(stretch)
        }
        return out
    }
}

/// What you corrected in a transcript, so the same mistake is caught next time: the misheard
/// words and what was meant ("bucked" → "booked", "Shona" → "Siobhan").
public struct LearnedFix: Codable, Equatable, Sendable {
    public var heard: String
    public var meant: String
    public var count: Int
    public init(heard: String, meant: String, count: Int = 1) { self.heard = heard; self.meant = meant; self.count = count }
}

public enum Fixes {
    /// The changes between a line as heard and as you fixed it, a few words each.
    public static func pairs(from old: String, to new: String) -> [(heard: String, meant: String)] {
        func words(_ s: String) -> [String] { s.split(whereSeparator: \.isWhitespace).map(String.init) }
        let a = words(old), b = words(new)
        return WordDiff.stretches(a.map(Doubts.normal), b.map(Doubts.normal)).compactMap { s in
            guard !s.removed.isEmpty, !s.inserted.isEmpty, s.removed.count <= 3, s.inserted.count <= 3 else { return nil }
            // What was meant, as you typed it (capitals and all).
            let j = WordDiff.position(of: s, in: a.map(Doubts.normal), b.map(Doubts.normal))
            let meant = b[j..<(j + s.inserted.count)].map { $0.trimmingCharacters(in: .punctuationCharacters) }.joined(separator: " ")
            return (s.removed.joined(separator: " "), meant)
        }
    }

    /// [learned] with the fixes from one edit added (or counted again), most used first.
    public static func learn(_ new: [(heard: String, meant: String)], into learned: [LearnedFix], limit: Int = 200) -> [LearnedFix] {
        var out = learned
        for (heard, meant) in new where !heard.isEmpty && !meant.isEmpty && heard != Doubts.normal(meant) {
            if let i = out.firstIndex(where: { $0.heard == heard && $0.meant == meant }) { out[i].count += 1 }
            else { out.append(LearnedFix(heard: heard, meant: meant)) }
        }
        return Array(out.sorted { $0.count > $1.count }.prefix(limit))
    }
}

extension WordDiff {
    /// Where in [b] a stretch's inserted words begin.
    static func position(of stretch: Stretch, in a: [String], _ b: [String]) -> Int {
        // Words of a before the stretch that are matched, plus words inserted earlier, give b's index.
        var i = 0, j = 0
        for s in stretches(a, b) {
            if s == stretch { return j + (s.at - i) }
            j += (s.at - i) + s.inserted.count
            i = s.at + s.removed.count
        }
        return j
    }
}
