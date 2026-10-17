import Foundation

/// Ask's questions and answers, kept on the iPhone so a day can be looked back on: as long as
/// Keep Transcripts, written after each one, off the main thread. Deleted with everything else
/// (Settings › Delete All Recordings).
enum ChatLog {
    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ask.json")
    }
    private static let queue = DispatchQueue(label: "wtf.asklog")
    /// As long as Keep Transcripts: a question shouldn't outlast the conversations it was about,
    /// nor go before them (Settings doesn't say it would).
    private static var since: Date {
        let set = UserDefaults.standard.integer(forKey: "keepDays")
        let days = set == 0 ? 7 : set
        return Date().addingTimeInterval(-Double(days) * 86_400)
    }

    static func load() -> [ChatMessage] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        do {
            let since = Self.since
            return try JSONDecoder().decode([ChatMessage].self, from: data).filter { $0.date >= since }
        } catch {
            Log.error("Couldn't read Ask's history", error)
            return []
        }
    }

    static func save(_ messages: [ChatMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        queue.async {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            do { try data.write(to: file, options: .atomic) } catch { Log.error("Couldn't save Ask's history", error) }
        }
    }
}
