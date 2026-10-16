import Foundation
import WTFCore

/// What you've corrected in transcripts ("bucked" → "booked", "Shona" → "Siobhan"), kept so the
/// same mistakes are caught next time: the corrections are given to the AI that fixes misheard
/// words, and what you meant goes to the recogniser as words to expect. Kept with WTF's other
/// data (not in the settings, which go in backups).
enum Learned {
    /// Where earlier versions kept them.
    private static let key = "learnedFixes"

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("learned.json")
    }

    static var fixes: [LearnedFix] {
        get {
            if let data = try? Data(contentsOf: file) { return (try? JSONDecoder().decode([LearnedFix].self, from: data)) ?? [] }
            // Moved out of the settings once.
            guard let old = UserDefaults.standard.data(forKey: key) else { return [] }
            let fixes = (try? JSONDecoder().decode([LearnedFix].self, from: old)) ?? []
            save(fixes)
            UserDefaults.standard.removeObject(forKey: key)
            return fixes
        }
        set { save(newValue) }
    }

    static func add(_ pairs: [(heard: String, meant: String)]) {
        guard !pairs.isEmpty else { return }
        fixes = Fixes.learn(pairs, into: fixes)
    }

    static func forget() {
        try? FileManager.default.removeItem(at: file)
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static func save(_ fixes: [LearnedFix]) {
        guard let data = try? JSONEncoder().encode(fixes) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }
}
