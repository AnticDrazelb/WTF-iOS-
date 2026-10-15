import Foundation

// Who's who. Each recording is split into "who spoke when" on the phone (local voices, numbered
// afresh every time); this matches those voices to the ones already heard in the conversation and
// to the people you've named, and lines the words up with whoever was speaking.

/// A voice heard in a conversation: its label in the transcript and its average voiceprint.
public struct Voiceprint: Codable, Equatable, Sendable {
    public var label: String
    public var print: [Float]
    /// How much speech the print is averaged over: longer counts for more.
    public var seconds: Double
    public init(label: String, print: [Float], seconds: Double) { self.label = label; self.print = print; self.seconds = seconds }

    /// Folds more of the same voice into the average.
    public mutating func add(_ other: [Float], seconds more: Double) {
        guard other.count == print.count, more > 0 else { return }
        let w = seconds, m = more
        print = VoiceMath.normalised(zip(print, other).map { (Float(w) * $0 + Float(m) * $1) / Float(w + m) })
        seconds += more
    }
}

/// Someone you've named, recognised from then on. You are the one with [isMe].
public struct KnownVoice: Equatable, Sendable {
    public var name: String
    public var print: [Float]
    public var isMe: Bool
    public init(name: String, print: [Float], isMe: Bool) { self.name = name; self.print = print; self.isMe = isMe }
    public var label: String { isMe ? Labels.me : name }
}

/// One voice found in a recording: an id that only means something within it.
public struct LocalVoice: Sendable {
    public var id: String
    public var print: [Float]
    public var seconds: Double
    /// When it first spoke (seconds into the recording): new voices are numbered in that order.
    public var firstAt: Double
    public init(id: String, print: [Float], seconds: Double, firstAt: Double) {
        self.id = id; self.print = print; self.seconds = seconds; self.firstAt = firstAt
    }
}

public enum VoiceMath {
    public static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na == 0 || nb == 0 ? 0 : d / (na * nb).squareRoot()
    }

    public static func normalised(_ v: [Float]) -> [Float] {
        let n = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return n > 0 ? v.map { $0 / n } : v
    }
}

public enum Labels {
    public static let me = "You"
    /// Every line, when voices aren't told apart.
    public static let anonymous = "Speech"

    public static func numbered(_ n: Int) -> String { "Speaker \(n)" }

    /// The N in "Speaker N", or nil for a name.
    public static func number(_ label: String) -> Int? {
        label.hasPrefix("Speaker ") ? Int(label.dropFirst(8)) : nil
    }

    /// A name typed for a voice, tidied for a transcript line ("[11:40] Name: …"), or nil if unusable.
    public static func cleanName(_ typed: String) -> String? {
        let t = typed.components(separatedBy: CharacterSet(charactersIn: ":[]\n\r\t")).joined(separator: " ")
            .split(separator: " ").joined(separator: " ")
        guard !t.isEmpty, t.count <= 30, number(t) == nil, t != anonymous else { return nil }
        if t.lowercased() == "me" || t.lowercased() == "you" { return me }
        return t
    }

    /// The labels speaking in a transcript, in the order they first spoke.
    public static func speakers(in transcript: String) -> [String] {
        var out: [String] = []
        for line in transcript.split(separator: "\n") {
            if let g = TranscriptFormat.turn.whole(String(line)), !out.contains(g[1]) { out.append(g[1]) }
        }
        return out
    }

    /// Every line by [from] said by [to] instead.
    public static func rename(_ transcript: String, from: String, to: String) -> String {
        transcript.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            guard let close = line.firstIndex(of: "]") else { return line }
            let rest = line[line.index(after: close)...]
            let prefix = " \(from): "
            guard rest.hasPrefix(prefix) else { return line }
            return String(line[...close]) + " \(to): " + rest.dropFirst(prefix.count)
        }.joined(separator: "\n")
    }

    /// "Speaker 2" in a title or summary, replaced by a name (whole words only).
    public static func renameInText(_ text: String, from: String, to: String) -> String {
        Rx("\\b" + NSRegularExpression.escapedPattern(for: from) + "\\b", caseSensitive: true).replace(text, with: NSRegularExpression.escapedTemplate(for: to))
    }
}

/// Gives each voice in a recording its label in the conversation.
public enum VoiceMatcher {
    /// Same voice as one already heard in this conversation (WeSpeaker; same voice ≈ 0.6–0.8, others ≈ 0–0.3).
    public static let sameVoice: Float = 0.5
    /// One of the people you've named: held to a bit more, as a wrong name is worse than a number.
    public static let knownVoice: Float = 0.55
    /// Less than this much speech is too little to be sure it's someone new.
    public static let newVoiceSeconds = 1.5

    /// - Parameters:
    ///   - local: the voices in this recording.
    ///   - heard: the conversation's voices so far; updated with this recording's.
    ///   - known: the people you've named.
    /// - Returns: local id → label ("You", a name, or "Speaker N").
    public static func label(_ local: [LocalVoice], heard: inout [Voiceprint], known: [KnownVoice]) -> [String: String] {
        var out: [String: String] = [:]
        var fresh: [LocalVoice] = []
        // The voices with the most speech have the steadiest prints, so they're matched first.
        for v in local.sorted(by: { $0.seconds > $1.seconds }) {
            let person = known.map { ($0, VoiceMath.cosine($0.print, v.print)) }.max { $0.1 < $1.1 }
            let earlier = heard.indices.map { ($0, VoiceMath.cosine(heard[$0].print, v.print)) }.max { $0.1 < $1.1 }
            if let (p, s) = person, s >= knownVoice, s >= (earlier?.1 ?? -1) - 0.05 {
                out[v.id] = p.label
                if let i = heard.firstIndex(where: { $0.label == p.label }) { heard[i].add(v.print, seconds: v.seconds) }
                else { heard.append(Voiceprint(label: p.label, print: VoiceMath.normalised(v.print), seconds: v.seconds)) }
            } else if let (i, s) = earlier, s >= sameVoice || (v.seconds < newVoiceSeconds && !heard.isEmpty) {
                out[v.id] = heard[i].label
                heard[i].add(v.print, seconds: v.seconds)
            } else {
                fresh.append(v)
            }
        }
        // Someone new: the next number, in the order they first spoke.
        var next = (heard.compactMap { Labels.number($0.label) }.max() ?? 0) + 1
        for v in fresh.sorted(by: { $0.firstAt < $1.firstAt }) {
            let label = Labels.numbered(next)
            next += 1
            out[v.id] = label
            heard.append(Voiceprint(label: label, print: VoiceMath.normalised(v.print), seconds: v.seconds))
        }
        return out
    }

    /// The unnamed voice in a conversation that sounds most like [person], if one does: its label.
    public static func match(_ person: KnownVoice, in heard: [Voiceprint]) -> String? {
        heard.filter { Labels.number($0.label) != nil }
            .map { ($0.label, VoiceMath.cosine($0.print, person.print)) }
            .filter { $0.1 >= knownVoice }
            .max { $0.1 < $1.1 }?.0
    }
}

/// Lines the recogniser's words up with "who spoke when".
public enum SpeakerAlign {
    public struct Word: Equatable, Sendable {
        public var start: Double, end: Double, text: String
        /// How sure the recogniser was of it (0–1), if it said.
        public var confidence: Double?
        /// What else the recogniser thought it might have been, likeliest first.
        public var alternatives: [String]
        public init(start: Double, end: Double, text: String, confidence: Double? = nil, alternatives: [String] = []) {
            self.start = start; self.end = end; self.text = text; self.confidence = confidence; self.alternatives = alternatives
        }
    }

    public struct Turn: Equatable, Sendable {
        public var start: Double, end: Double, speaker: String
        public init(start: Double, end: Double, speaker: String) { self.start = start; self.end = end; self.speaker = speaker }
    }

    public struct Said: Equatable, Sendable {
        public var start: Double, speaker: String, text: String
    }

    /// A word this far from any turn still goes to the nearest one.
    static let reach = 1.0
    /// A blip of another voice shorter than this, with fewer than [blipWords] words, inside one
    /// speaker's run, is a mislabelled word, not an interruption.
    static let blipSeconds = 0.6
    static let blipWords = 3

    /// Who said what, in order. Words no turn reaches go to [fallback] (or whoever spoke just before).
    public static func assign(_ words: [Word], turns: [Turn], fallback: String) -> [Said] {
        guard !words.isEmpty else { return [] }
        var who: [String] = []
        for w in words {
            var best: (speaker: String, overlap: Double)?
            var nearest: (speaker: String, distance: Double)?
            for t in turns {
                let overlap = min(w.end, t.end) - max(w.start, t.start)
                if overlap > 0, overlap > (best?.overlap ?? 0) { best = (t.speaker, overlap) }
                let distance = max(t.start - w.end, w.start - t.end, 0)
                if distance < (nearest?.distance ?? .infinity) { nearest = (t.speaker, distance) }
            }
            if let best { who.append(best.speaker) }
            else if let nearest, nearest.distance <= reach { who.append(nearest.speaker) }
            else { who.append(who.last ?? fallback) }
        }
        snapToSentences(words, &who)
        // Runs of the same voice, then blips smoothed into the voice around them.
        var runs: [(speaker: String, range: Range<Int>)] = []
        for i in words.indices {
            if let last = runs.last, last.speaker == who[i] { runs[runs.count - 1].range = last.range.lowerBound..<(i + 1) }
            else { runs.append((who[i], i..<(i + 1))) }
        }
        var i = 1
        while i < runs.count - 1 {
            let r = runs[i]
            let length = words[r.range.upperBound - 1].end - words[r.range.lowerBound].start
            if runs[i - 1].speaker == runs[i + 1].speaker, r.range.count < blipWords, length < blipSeconds {
                runs[i - 1].range = runs[i - 1].range.lowerBound..<runs[i + 1].range.upperBound
                runs.removeSubrange(i...(i + 1))
            } else {
                i += 1
            }
        }
        return runs.map { r in
            let text = tidy(join(words[r.range].map(\.text)))
            return Said(start: words[r.range.lowerBound].start, speaker: r.speaker, text: text)
        }.filter { !$0.text.isEmpty }
    }

    /// The voice splitter tends to mark a change of speaker a word or so late, so the new
    /// speaker's first words ("Yeah,", "Why", "You") end up on the last speaker's line. The
    /// recogniser's punctuation knows better: if the old speaker's line had a sentence end in its
    /// last few words, the change really came there, and what follows is the new speaker's.
    static let lateWords = 3
    static let lateSeconds = 1.5

    static func snapToSentences(_ words: [Word], _ who: inout [String]) {
        var i = 1
        while i < words.count {
            defer { i += 1 }
            guard who[i] != who[i - 1], !endsSentence(words[i - 1].text) else { continue }
            let old = who[i - 1]
            var k = i - 2
            while k >= 0, k >= i - 1 - lateWords, who[k] == old {
                if endsSentence(words[k].text) {
                    if words[i - 1].end - words[k + 1].start <= lateSeconds {
                        for m in (k + 1)..<i { who[m] = who[i] }
                    }
                    break
                }
                k -= 1
            }
        }
    }

    static func endsSentence(_ word: String) -> Bool {
        guard let last = word.trimmingCharacters(in: .whitespaces).last else { return false }
        return ".?!\u{2026}".contains(last)
    }

    /// No stray punctuation at the start ("". Cool" → "Cool"), none doubled at the end ("?." → "?").
    static func tidy(_ text: String) -> String {
        var t = text
        while let first = t.first, ".,;:!?".contains(first) { t.removeFirst(); t = t.trimmingCharacters(in: .whitespaces) }
        return Rx(#"([.?!])[.,]+(?=\s|$)"#).replace(t, with: "$1")
    }

    /// Words back into text: recognisers' words may or may not carry their own spaces.
    public static func join(_ pieces: [String]) -> String {
        var out = ""
        for p in pieces {
            if let last = out.last, !last.isWhitespace, let first = p.first, !first.isWhitespace, !".,!?;:%)\u{2019}'".contains(first) {
                out += " "
            }
            out += p
        }
        return out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// How long each voice spoke for and when it started, from its turns.
    public static func totals(_ turns: [Turn]) -> [String: (seconds: Double, firstAt: Double)] {
        var out: [String: (seconds: Double, firstAt: Double)] = [:]
        for t in turns {
            let had = out[t.speaker] ?? (0, t.start)
            out[t.speaker] = (had.seconds + max(0, t.end - t.start), min(had.firstAt, t.start))
        }
        return out
    }
}
