import Contacts
import EventKit
import UIKit
import WTFCore

/// Words from your own world for the recogniser to expect: names from your contacts, and the
/// names and places in your calendar. Both are optional (Settings), and nothing leaves the phone.
/// The calendar is also how heard appointments are checked ("already in your calendar").
enum PersonalWords {
    static var useContacts: Bool { UserDefaults.standard.bool(forKey: "useContacts") }
    static var useCalendar: Bool { UserDefaults.standard.bool(forKey: "useCalendar") }

    static var contactsAllowed: Bool {
        let s = CNContactStore.authorizationStatus(for: .contacts)
        return s == .authorized || s == .limited
    }

    static var calendarAllowed: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    static func askForContacts() async -> Bool {
        do { return try await CNContactStore().requestAccess(for: .contacts) } catch {
            Log.error("Contacts access", error)
            return false
        }
    }

    static func askForCalendar() async -> Bool {
        do { return try await EKEventStore().requestFullAccessToEvents() } catch {
            Log.error("Calendar access", error)
            return false
        }
    }

    private static let cache = Cache()

    /// Contacts' names (unusual ones first: the recogniser knows common names already) and the
    /// calendar's names and places from the last week to the next month. Worked out once an hour.
    static func words() async -> [String] {
        if let fresh = cache.get() { return fresh }
        var names = contactNames()
        if !names.isEmpty {
            let all = names
            names = await MainActor.run {
                let checker = UITextChecker()
                func unusual(_ w: String) -> Bool {
                    checker.rangeOfMisspelledWord(in: w, range: NSRange(location: 0, length: (w as NSString).length),
                                                  startingAt: 0, wrap: false, language: "en_GB").location != NSNotFound
                }
                let flags = all.map(unusual)
                return zip(all, flags).filter { $0.1 }.map(\.0) + zip(all, flags).filter { !$0.1 }.map(\.0)
            }
        }
        let words = Array(names.prefix(60)) + calendarWords()
        cache.set(words)
        return words
    }

    static func forget() { cache.clear() }

    static func contactNames() -> [String] {
        guard useContacts, contactsAllowed else { return [] }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey] as [CNKeyDescriptor]
        var names: [String] = []
        var seen = Set<String>()
        do {
            try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in
                for n in [c.givenName, c.familyName, c.nickname] {
                    let t = n.trimmingCharacters(in: .whitespaces)
                    if t.count >= 2, t.count <= 30, seen.insert(t.lowercased()).inserted { names.append(t) }
                }
            }
        } catch {
            Log.error("Reading contacts' names", error)
        }
        return names
    }

    /// What's in the calendar between two dates.
    static func calendarEntries(from: Date, to: Date) -> [CalendarCheck.Entry] {
        guard useCalendar, calendarAllowed else { return [] }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: nil))
        return events.map { CalendarCheck.Entry(title: $0.title ?? "", start: $0.startDate, allDay: $0.isAllDay) }
    }

    static func calendarWords() -> [String] {
        guard useCalendar, calendarAllowed else { return [] }
        let store = EKEventStore()
        let now = Date()
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-7 * 86_400),
                                                                     end: now.addingTimeInterval(30 * 86_400), calendars: nil))
        var out: [String] = []
        for e in events.prefix(200) {
            // A short title is a name in itself ("Dentist", "Sarah's party"); longer ones, their capitalised words.
            if let title = e.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
                if title.split(separator: " ").count <= 3 { out.append(title) }
                else { out += KnownFacts.names(in: [title]) }
            }
            if let place = e.location?.components(separatedBy: CharacterSet(charactersIn: ",\n")).first?.trimmingCharacters(in: .whitespaces),
               !place.isEmpty, place.count <= 40 {
                out.append(place)
            }
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0.lowercased()).inserted }
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (at: Date, words: [String])?

        func get() -> [String]? {
            lock.lock(); defer { lock.unlock() }
            guard let value, Date().timeIntervalSince(value.at) < 3600 else { return nil }
            return value.words
        }

        func set(_ words: [String]) { lock.lock(); value = (Date(), words); lock.unlock() }
        func clear() { lock.lock(); value = nil; lock.unlock() }
    }
}
