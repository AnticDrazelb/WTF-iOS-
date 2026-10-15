import Foundation
import NaturalLanguage

/// Whether a word someone was called is a person's name: Apple's on-device name tagger, plus
/// what families call each other.
enum NameCheck {
    static let family: Set<String> = ["Mum", "Mam", "Mom", "Mummy", "Mommy", "Dad", "Daddy", "Nan", "Nana", "Nanna", "Gran",
                                      "Granny", "Grandma", "Grandad", "Grandpa", "Auntie", "Aunty", "Uncle"]
    static let never: Set<String> = ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday", "January",
                                     "February", "March", "April", "May", "June", "July", "August", "September", "October",
                                     "November", "December", "God", "Jesus", "Christ", "Sir", "Madam", "Mate", "Love", "Darling",
                                     "Babe", "Guys", "Lads", "Okay", "Yeah", "Yes", "No", "Honestly", "Seriously", "Really", "Anyway"]

    static func isName(_ word: String) -> Bool {
        if family.contains(word) { return true }
        if never.contains(word) { return false }
        let sentence = "I was talking to \(word) about it yesterday."
        guard let at = sentence.range(of: word) else { return false }
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = sentence
        let (tag, _) = tagger.tag(at: at.lowerBound, unit: .word, scheme: .nameType)
        return tag == .personalName
    }
}
