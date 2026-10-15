import Foundation

/// Music isn't conversation: songs on the radio or the TV shouldn't fill transcripts with lyrics.
/// Apple's sound classifier scores each second of a recording for music, singing and speech; a
/// recording is skipped only if it's clearly a song, so talk over background music is kept.
public enum MusicFilter {
    public struct Window: Sendable {
        public var music: Double, singing: Double, speech: Double
        public init(music: Double, singing: Double, speech: Double) { self.music = music; self.singing = singing; self.speech = speech }
    }

    public static func isSong(_ windows: [Window]) -> Bool {
        guard windows.count >= 3 else { return false }
        let song = windows.filter { w in (w.music >= 0.5 && w.singing >= 0.3 && w.singing >= w.speech * 0.8) || (w.music >= 0.8 && w.speech < 0.3) }.count
        // Talk counts as talk whatever's playing behind it (a car radio, the TV).
        let talk = windows.filter { $0.speech >= 0.6 && $0.speech >= $0.singing }.count
        return Double(song) >= 0.7 * Double(windows.count) && Double(talk) < 0.15 * Double(windows.count)
    }
}

/// A finished conversation heard again as a whole: its recordings joined into one, with a short
/// gap between each, and times in the joined audio mapped back to the clock.
public struct JoinedAudio: Sendable {
    public struct Piece: Sendable {
        /// Where it starts in the joined audio (seconds), how long it is, and when it was recorded.
        public var at: Double, length: Double, recorded: Date
        public init(at: Double, length: Double, recorded: Date) { self.at = at; self.length = length; self.recorded = recorded }
    }

    public var pieces: [Piece] = []
    public static let gap = 0.5

    public init() {}

    public var length: Double { pieces.last.map { $0.at + $0.length } ?? 0 }

    public mutating func add(length: Double, recorded: Date) {
        let at = pieces.isEmpty ? 0 : self.length + Self.gap
        pieces.append(Piece(at: at, length: length, recorded: recorded))
    }

    /// The clock time of [seconds] into the joined audio (a gap counts as the end of the piece before it).
    public func time(at seconds: Double) -> Date {
        guard let piece = pieces.last(where: { $0.at <= seconds + 0.01 }) ?? pieces.first else { return Date(timeIntervalSince1970: 0) }
        return piece.recorded.addingTimeInterval(min(max(0, seconds - piece.at), piece.length))
    }

    /// Whether a new transcript of the whole is safe to use instead of the one built as it went:
    /// about as many words (the recogniser didn't lose a stretch or repeat one).
    public static func accept(old: String, new: String) -> Bool {
        func count(_ t: String) -> Int {
            t.split(separator: "\n").compactMap { TranscriptFormat.turn.whole(String($0))?[2] }
                .reduce(0) { $0 + $1.split(separator: " ").count }
        }
        let a = count(old), b = count(new)
        guard a > 0, b > 0 else { return false }
        return Double(b) >= 0.85 * Double(a) && Double(b) <= 1.25 * Double(a)
    }
}
