import Foundation
import NaturalLanguage

/// What a sentence means, as numbers (Apple's built-in sentence embedding, on the phone), so a
/// question finds what it's about even in different words: "where are we having the party?"
/// finds "the back room at the Crown".
enum Meaning {
    private static let embedding = NLEmbedding.sentenceEmbedding(for: .english)

    static var available: Bool { embedding != nil }

    static func vector(_ text: String) -> [Double]? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return embedding?.vector(for: String(t.prefix(1_000)))
    }

    /// 0 (unrelated) to 1 (the same).
    static func similarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var d = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na == 0 || nb == 0 ? 0 : max(0, d / (na * nb).squareRoot())
    }
}
