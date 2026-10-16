import Foundation
import os

/// What went wrong, and when, kept on the phone so it can be shared (Settings › Share Diagnostics).
/// Also goes to the system log, for Console.app. Never holds what was said, only what happened.
enum Log {
    private static let system = Logger(subsystem: "com.wtf.ios", category: "wtf")
    private static let queue = DispatchQueue(label: "wtf.log")
    /// Kept to about this size: the older half goes when it's reached.
    private static let maxBytes = 256 * 1024

    static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("wtf.log")
    }

    static func info(_ message: String) { write("    ", message) }

    static func error(_ message: String, _ error: Error? = nil) {
        write("ERR ", message + (error.map { ": \(describe($0))" } ?? ""))
    }

    /// Runs [body], logging (not throwing) a failure: for the places where carrying on is right
    /// but silence isn't.
    @discardableResult
    static func attempt<T>(_ what: String, _ body: () async throws -> T) async -> T? {
        do { return try await body() } catch {
            Log.error(what, error)
            return nil
        }
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(error.localizedDescription) [\(e.domain) \(e.code)]"
    }

    private static func write(_ level: String, _ message: String) {
        let line = "\(stamp()) \(level)\(message)\n"
        if level.hasPrefix("ERR") { system.error("\(message, privacy: .public)") } else { system.info("\(message, privacy: .public)") }
        queue.async {
            let url = file
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                let size = handle.offsetInFile
                try? handle.close()
                if size > maxBytes, let data = try? Data(contentsOf: url) {
                    // From the start of a line, so no character's cut in half.
                    var kept = data.suffix(maxBytes / 2)
                    if let newline = kept.firstIndex(of: 10) { kept = kept[(newline + 1)...] }
                    try? Data(kept).write(to: url)
                }
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f.string(from: Date())
    }

    /// The last [lines] lines.
    static func tail(_ lines: Int = 400) -> String {
        queue.sync {
            // Leniently: a log cut part-way through a character by an earlier version still reads.
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { return "(empty)" }
            let text = String(decoding: data, as: UTF8.self)
            return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
        }
    }
}
