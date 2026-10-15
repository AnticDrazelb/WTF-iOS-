import Foundation
import WTFCore

/// What you've corrected in transcripts ("bucked" → "booked", "Shona" → "Siobhan"), kept so the
/// same mistakes are caught next time: the corrections are given to the AI that fixes misheard
/// words, and what you meant goes to the recogniser as words to expect.
enum Learned {
    private static let key = "learnedFixes"

    static var fixes: [LearnedFix] {
        get { UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([LearnedFix].self, from: $0) } ?? [] }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func add(_ pairs: [(heard: String, meant: String)]) {
        guard !pairs.isEmpty else { return }
        fixes = Fixes.learn(pairs, into: fixes)
    }

    static func forget() { UserDefaults.standard.removeObject(forKey: key) }
}
