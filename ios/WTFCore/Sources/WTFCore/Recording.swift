import Foundation

/// How the recorder cuts speech into pieces (ported from the Android app, same numbers):
/// a piece ends after 8 s of quiet; past 25 s it ends at the next pause instead, so long
/// talks are transcribed as they go; 5 minutes caps one with no pauses at all.
public enum ChunkRules {
    public enum End: Equatable, Sendable { case quiet, cut }

    public static let silenceToCloseMs = 8_000
    public static let softChunkMs = 25_000
    public static let pauseMs = 600
    public static let shortPauseMs = 300
    public static let maxChunkMs = 5 * 60_000
    /// A chunk with less speech than this is a cough or a door, unless it carries on after a cut.
    public static let minSpeechMs = 1_500

    public static func end(lengthMs: Int, quietMs: Int) -> End? {
        if quietMs > silenceToCloseMs { return .quiet }
        if lengthMs > maxChunkMs { return .cut }
        if lengthMs > softChunkMs && quietMs >= (lengthMs > 2 * softChunkMs ? shortPauseMs : pauseMs) { return .cut }
        return nil
    }
}

/// Energy-based voice activity with an adaptive noise floor (as on Android): cheap enough for
/// every 30 ms of audio all day. Loud non-speech gets through; the speech recogniser drops it.
public struct EnergyVad: Sendable {
    var floor = 300.0 / 32768.0
    static let minFloor = 50.0 / 32768.0
    static let ratio = 3.0
    static let absoluteMin = 250.0 / 32768.0

    public init() {}

    /// [samples] are -1…1 floats.
    public mutating func isSpeech(_ samples: UnsafeBufferPointer<Float>) -> Bool {
        guard !samples.isEmpty else { return false }
        var sum = 0.0
        for s in samples { sum += Double(s) * Double(s) }
        let rms = (sum / Double(samples.count)).squareRoot()
        floor = rms < floor ? 0.9 * floor + 0.1 * rms : 0.9995 * floor + 0.0005 * rms
        floor = Swift.max(floor, Self.minFloor)
        return rms > floor * Self.ratio && rms > Self.absoluteMin
    }

    public mutating func isSpeech(_ samples: [Float]) -> Bool { samples.withUnsafeBufferPointer { isSpeech($0) } }
}

/// Why iOS wouldn't let the microphone come on, in a few plain words, from its error code (iOS's
/// audio errors are four letters packed into a number). Nil for one it doesn't say much about.
public enum MicTrouble {
    public static func code(_ letters: String) -> Int { letters.utf8.reduce(0) { $0 << 8 | Int($1) } }

    public static func reason(_ code: Int) -> String? {
        switch code {
        case Self.code("!pri"): return "a call or another app is using it"
        case Self.code("siri"): return "Siri is listening"
        case Self.code("!rec"), Self.code("!pla"), Self.code("!int"): return "iOS wouldn\u{2019}t allow it just then"
        case Self.code("msrv"): return "the iPhone\u{2019}s sound system was restarting"
        case Self.code("!act"): return "the iPhone\u{2019}s sound was busy"
        default: return nil
        }
    }
}
