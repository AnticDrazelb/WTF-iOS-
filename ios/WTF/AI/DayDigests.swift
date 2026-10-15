import Foundation
import WTFCore

/// "Your Day": the few sentences at the top of each day in the Timeline, written by Apple
/// Intelligence from that day's conversation notes. Kept on the iPhone (the last 60 days), and
/// written again only when the day's had another conversation summarised, or one renamed.
@MainActor
final class DayDigests {
    static let shared = DayDigests()

    private struct Kept: Codable {
        /// What it was written from (see fingerprint).
        var from: String
        var text: String
    }

    private var kept: [String: Kept]
    private var busy = false

    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("days.json")
    }

    private init() {
        kept = (try? Data(contentsOf: Self.file)).flatMap { try? JSONDecoder().decode([String: Kept].self, from: $0) } ?? [:]
    }

    /// The day's recap as last written, even if there's been more since.
    func last(for day: Date) -> String? { kept[Self.key(day)]?.text }

    /// Whether it needs writing (again) for these notes, and can be.
    func needsWriting(_ day: Date, notes: [DayNote]) -> Bool {
        !notes.isEmpty && Brain.notReadyReason == nil && kept[Self.key(day)]?.from != Self.fingerprint(notes)
    }

    /// The day's recap, written now if there isn't one for these notes yet, one day at a time.
    /// Nil without Apple Intelligence, or if it couldn't be written.
    func recap(for day: Date, notes: [DayNote]) async -> String? {
        let key = Self.key(day), from = Self.fingerprint(notes)
        if let k = kept[key], k.from == from { return k.text }
        guard !notes.isEmpty, Brain.notReadyReason == nil else { return nil }
        while busy {
            try? await Task.sleep(for: .milliseconds(250))
            if Task.isCancelled { return nil }
        }
        // Another page may have written it while this one waited.
        if let k = kept[key], k.from == from { return k.text }
        busy = true
        defer { busy = false }
        do {
            let text = try await Brain.day(Prompts.day(notes, today: Calendar.current.isDateInToday(day)))
            guard !text.isEmpty else { return nil }
            kept[key] = Kept(from: from, text: text)
            save()
            return text
        } catch {
            Log.error("Couldn't write the day's recap", error)
            return nil
        }
    }

    /// A conversation deleted: its day's recap goes until it's written again without it.
    func forget(day: Date) {
        kept[Self.key(day)] = nil
        save()
    }

    /// Settings › Delete All Recordings.
    func forget() {
        kept = [:]
        try? FileManager.default.removeItem(at: Self.file)
    }

    private func save() {
        let since = Self.key(Date().addingTimeInterval(-60 * 86_400))
        kept = kept.filter { $0.key >= since } // "yyyy-MM-dd" sorts as the days do
        guard let data = try? JSONEncoder().encode(kept) else { return }
        let file = Self.file
        Task.detached(priority: .utility) { try? data.write(to: file, options: .atomic) }
    }

    static func key(_ day: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    /// What a recap's written from: changes when a conversation's added, summarised or renamed.
    static func fingerprint(_ notes: [DayNote]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV-1a: the same from one launch to the next
        for n in notes.sorted(by: { $0.start < $1.start }) {
            for byte in "\(Int(n.start.timeIntervalSince1970))|\(n.title)|\(n.points.joined())\n".utf8 {
                hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
            }
        }
        return String(hash, radix: 16)
    }
}
