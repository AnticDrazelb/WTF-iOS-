import Foundation

public enum ActionType: String, Codable, Sendable { case event = "EVENT", buy = "BUY", todo = "TODO" }

/// Something worth acting on, pulled out of a conversation.
public struct ExtractedAction: Equatable, Sendable {
    public var type: ActionType
    public var title: String
    /// The date/time words as spoken (appointments only).
    public var whenText: String?
    public var place: String?
    /// [whenText] resolved against when the conversation happened; nil if unclear.
    public var resolved: WhenResult?
    /// What to check before relying on it: "Not booked yet", "Date not certain", or a date
    /// that doesn't add up. Nil when it was said plainly.
    public var note: String?
    /// The transcript line it was heard in ("[14:09:12] You: …"), to show where it came from.
    public var source: String?

    public init(type: ActionType, title: String, whenText: String? = nil, place: String? = nil, resolved: WhenResult? = nil,
                note: String? = nil, source: String? = nil) {
        self.type = type; self.title = title; self.whenText = whenText; self.place = place; self.resolved = resolved
        self.note = note; self.source = source
    }
}

/// Finds appointments, shopping and to-dos in transcript lines ("[11:40:02] You: …"). Cheap cues
/// pick the lines worth reading; precise rules find items with no AI at all; the AI's own
/// findings are merged in when the phone has one. (Ported from the Android app.)
public enum ActionRules {
    static let eventCues = Rx(
        #"\b(appointment|meeting|dentist|doctor'?s?|gp|hospital|vet|interview|booked|book (it|a|in)|reservation|"# +
        #"party|wedding|birthday|dinner|lunch|drinks|deadline|flight|train|match|gig|"# +
        #"monday|tuesday|wednesday|thursday|friday|saturday|sunday|tomorrow|tonight|next week|weekend|"# +
        #"\d{1,2}(:\d\d)?\s*(am|pm|a\.m\.|p\.m\.)|o'clock|half (past )?(one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d)|"# +
        #"the \d{1,2}(st|nd|rd|th))\b"#)
    static let buyCues = Rx(
        #"\b(buy|bought|get (some|more|a|an|the)|pick up|picking up|grab|need (some|more)|run(ning)? out|ran out|"# +
        #"needs? (new|some|more)|out of|shopping|groceries|supermarket|tesco|sainsbury'?s|asda|aldi|lidl|we'?ve got no|there'?s no)\b"#)
    static let todoCues = Rx(
        #"\b(i'?ll|i will|i need to|i have to|i must|i've got to|i gotta|remind me|don'?t forget|"# +
        #"remember to|i should|i'm going to|i promised)\b"#)

    /// Lines that might hold something to act on, each with the line after it for context.
    public static func candidateLines(_ transcript: String) -> [String] {
        let lines = transcript.split(separator: "\n").map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var keep = Set<Int>()
        for (i, l) in lines.enumerated() {
            let text = l.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
            if eventCues.test(text) || buyCues.test(text) || todoCues.test(text) {
                keep.insert(i)
                if i + 1 < lines.count { keep.insert(i + 1) }
            }
        }
        return keep.sorted().map { lines[$0] }
    }

    /// A word of an item: not one that ends it ("milk from Tesco" is milk).
    static let itemWord = #"(?!(?:for|on|by|from|at|when|tomorrow|today|tonight|later|please|too|again|if|because|so|then)\b)[a-z][a-z'-]*"#
    static let item = "(" + itemWord + #"(?:\s+"# + itemWord + #"){0,2}(?:(?:\s*,\s*|\s+and\s+)"# + itemWord + #"(?:\s+"# + itemWord + "){0,2})*)"
    static let itemEnd = #"(?=\s+(?:for|on|by|from|at|when|tomorrow|today|tonight|later|please|too|as well|again|on the way|if|because|so)\b|[.,!?]|$)"#
    static let buyRules = [
        Rx(#"\b(?:pick up|picking up|buy|grab|get|order)\s+(?:some|more|a few|a couple of|a|an|the|new)\s+"# + item + itemEnd),
        Rx(#"\b(?:buy|grab|pick up)\s+"# + item + itemEnd),
        Rx(#"\b(?:run(?:ning)? out of|ran out of|out of|we've got no|we have no|there's no)\s+"# + item + itemEnd),
        Rx(#"\bneed (?:some|more)\s+"# + item + itemEnd),
        // "we need batteries for the remote", "the remote needs new batteries"
        Rx(#"\b(?:we|i) need (?:new |a new |an? )?(?!to\b)"# + item + itemEnd),
        Rx(#"\bneeds (?:new |some |more |a new )\s*"# + item + itemEnd),
    ]
    static let notItems: Set<String> = [
        "it", "that", "this", "them", "those", "these", "one", "ones", "something", "anything", "time", "way", "back",
        "rid", "sorted", "ready", "going", "home", "there", "here", "him", "her", "you", "me", "us", "idea", "touch",
        "bit", "lot", "chance", "work", "bed", "sleep", "money", "breath", "luck", "date", "room", "link", "place",
        // Things you "get" that aren't shopping: "get a good answer", "get a look at it".
        "answer", "answers", "question", "look", "feel", "feeling", "sense", "job", "word", "view", "result", "reply",
        "response", "point", "problem", "picture", "grip", "hold", "kick", "laugh", "glimpse", "shot", "start", "break",
        "rest", "deal", "go", "say", "clue", "grade", "score", "good", "great", "bad", "better", "best", "worse", "worst",
        // People you pick up or grab aren't shopping: "pick up the kids", "grab my mum".
        "kids", "kid", "children", "child", "son", "daughter", "mum", "mom", "dad", "nan", "nana", "gran", "grandma", "grandad",
        "granddad", "baby", "friend", "friends", "boys", "girls", "wife", "husband", "partner", "brother", "sister", "family",
        "people", "guys", "lads", "everyone", "everybody",
    ]
    /// Collecting someone, not buying something: "pick up Ezra from school", "collect the kids from nursery".
    static let collecting = Rx(#"\b(?:pick|picking|collect|collecting|fetch|fetching)\b.{0,40}\bfrom (?:school|nursery|pre-?school|college|uni|university|work|the station|the airport|practice|training|football|swimming|club|cubs|scouts|brownies|ballet|the party|(?:his|her|their|your|my) (?:mum|mom|dad|nan|gran|grandma|grandad|friend)'?s?)\b"#)

    static let todoRule = Rx(
        #"\b(?:i'?ll|i will|i need to|i have to|i've got to|i must|remind me to|don'?t forget to|remember to|i'm going to|i promised to)\s+(.{4,80}?)\s*(?:[.!?]|$)"#)
    /// "get it sorted", "do that", "sort this out": no idea what the task actually is.
    static let vagueTask = Rx(#"^\w+\s+(it|that|this|them|one)(\s+\w+)?$"#)
    static let eventNoun = Rx(
        #"\b(?:([a-z]+'s) )?(appointment|dentist|dental|doctor|gp|vet|interview|meeting|party|birthday|wedding|anniversary|"# +
        #"dinner|lunch|drinks|deadline|flight|match|gig|check-up|checkup|game night|parents' evening|mot|service)\b"#)
    static let agreed = Rx(#"\b(works|perfect|booked|see you|confirmed|that's fine|sounds good|great|lovely|yes|yeah)\b"#)
    static let bogusEventTitle = Rx(#"^(discuss|discussing|talk|talking|chat|conversation|meeting for .* link)"#)
    static let vagueWhen = Rx(#"any ?time|unspecified|not (specified|said|given)|unknown|^\s*(nothing|none|n/?a|later|soon|sometime|some time|eventually)\s*$"#)
    static let clauses = Rx(#"[.?!;]\s+|,?\s+and then\s+|,\s+then\s+"#)
    /// Eating out isn't shopping: "grab some Chinese food from a restaurant".
    static let eatingOut = Rx(#"\b(restaurant|takeaway|take-away|takeout|chippy|caf[eé]|pub|bar|drive-?thru|deliveroo|just eat|uber eats|order in|eat out|eating out)\b"#)
    static let buyTodo = Rx(
        #"^(?:buy|get|grab|pick up|pick-up|order)\s+(?:some\s+|more\s+|a\s+|an\s+|the\s+|new\s+)?(.+?)"# +
        #"(?:\s+(?:tomorrow|today|tonight|later|on the way.*|from .*|at the .*|for (?:the|a) .*|when .*))?$"#)
    static let whoToRing = Rx(#"\bthe (garage|dentist|doctors?|surgery|vet|school|landlord|bank|council|restaurant|pub|hotel|plumber|builder|electrician|salon|hairdresser'?s?)\b"#)

    /// "Ring them to confirm" said about the garage and the MOT -> "Ring the garage to confirm the MOT".
    static func specific(_ task: String, in line: String) -> String {
        var out = task
        if let who = whoToRing.first(line) {
            out = Rx(#"^((?:ring|call|phone|text|email|ask|tell) )(them|him|her)\b"#).replace(out, with: "$1the " + who[1])
        }
        if Rx(#"\bto (confirm|check|book)$"#).test(out), let noun = eventNoun.first(line) {
            let thing = noun[2].count <= 3 ? noun[2].uppercased() : noun[2]
            out += " the " + thing
        }
        return out
    }

    /// A plan that isn't settled: suggested, or still to be booked or confirmed.
    static let unsettled = Rx(
        #"\b(need to (ring|call|phone|confirm|check|book)|(ring|call|phone) (them|the \w+) to|to confirm|confirm (it|that|with)|"# +
        #"haven'?t (booked|confirmed)|not booked|not confirmed|should we|shall we|how about|what about|maybe|might|"# +
        #"could (we|do|book)|pencil|provisional|i'?ll (ring|call|check|book)|if (it'?s|that'?s|they'?re) (free|ok|okay|open))\b"#)
    static let settled = Rx(#"\b((it'?s|is|all|i'?ve|we'?ve|got it|now) (booked|confirmed|sorted)|booked it|confirmed it|see you then)\b"#)
    /// Things that get booked: only these can be "Not booked yet" (picking someone up can't).
    static let bookable = Rx(
        #"\b(appointment|dentist|dental|doctor'?s?|gp|vet|hospital|clinic|interview|meeting|reservation|table|booking|book|booked|"# +
        #"tickets?|flight|train|coach|hotel|mot|service|haircut|hairdresser'?s?|barber'?s?|salon|massage|nails|class|lesson|session|"# +
        #"check-?up|restaurant|venue|room|party|tour)\b"#)

    /// The note for a plan heard in [said] (and the talk just after it): a date that doesn't add
    /// up, a date asked about rather than said, or a plan not yet booked, if [thing] (the plan,
    /// as said) is the kind of thing that gets booked.
    public static func planNote(_ resolved: WhenResult?, said: String, around: String, thing: String? = nil) -> String? {
        if let doubt = resolved?.doubt { return doubt }
        if said.trimmingCharacters(in: .whitespaces).hasSuffix("?") { return "Date not certain" }
        if unsettled.test(around) && !settled.test(around) && bookable.test(thing ?? around) { return "Not booked yet" }
        return nil
    }

    /// Whether most of [item]'s words were actually said in [lines]: the AI's finds are kept only
    /// if so ("Confirm McDonald's details" when all that was said was "go to McDonald's" isn't).
    public static func grounded(_ item: String, in lines: [String], share: Double = 0.5) -> Bool {
        let want = words(item)
        guard !want.isEmpty else { return false }
        let heard = lines.reduce(into: Set<String>()) { $0.formUnion(words(said($1))) }
        return Double(want.intersection(heard).count) / Double(want.count) >= share
    }

    /// Whether [item] is someone being collected in [lines] ("pick up Ezra from school", "grab
    /// the kids"), not something to buy: it comes straight after "pick up" (or "collect"), and
    /// it's a name, a person, or being fetched from somewhere like school.
    public static func isCollecting(_ item: String, in lines: [String]) -> Bool {
        guard let first = item.split(separator: " ").first.map({ String($0).lowercased() }) else { return false }
        let after = Rx(#"\b(?:pick(?:ing)?\s+up|collect(?:ing)?|fetch(?:ing)?|grab(?:bing)?)\s+(?:the\s+|my\s+|your\s+|his\s+|her\s+|our\s+|their\s+)?"# +
                       NSRegularExpression.escapedPattern(for: first) + #"\b"#)
        return lines.contains { line in
            let t = said(line)
            return after.test(t) && (item.first?.isUppercase == true || notItems.contains(first) || collecting.test(t))
        }
    }

    /// A transcript line's words ("[14:04:10] Speaker 1: Right, so…" → "Right, so…"), or the line
    /// as it is if it's just words.
    static func said(_ line: String) -> String {
        let t = text(line)
        return t.isEmpty ? line : t
    }

    /// Whether [plan] is the kind of thing that gets booked (so can be "Not booked yet").
    public static func isBookable(_ plan: String) -> Bool { bookable.test(plan) }

    /// A plan for the day it was heard, with no time said ("we're going to McDonald's",
    /// "it's his birthday today"): happening already, not one for the calendar.
    static func happeningToday(_ resolved: WhenResult, conversationStart: Date, calendar: Calendar) -> Bool {
        let d = calendar.dateComponents([.year, .month, .day], from: conversationStart)
        return resolved.allDay && resolved.year == d.year && resolved.month == d.month && resolved.day == d.day
    }

    /// The line in [lines] that [title] most likely came from: the one sharing most of its words.
    public static func sourceLine(_ title: String, in lines: [String]) -> String? {
        let want = words(title)
        guard !want.isEmpty else { return nil }
        let best = lines.map { ($0, words(text($0)).intersection(want).count) }.max { $0.1 < $1.1 }
        return best.flatMap { $0.1 > 0 ? $0.0 : nil }
    }

    static let notShopping = Rx(#"\b(card|present|gift|tickets?|appointment|room|table)\b"#)

    static func text(_ line: String) -> String {
        let afterTime = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ")
        return afterTime.components(separatedBy: ": ").dropFirst().joined(separator: ": ")
    }
    static func speaker(_ line: String) -> String {
        let afterTime = line.components(separatedBy: "] ").dropFirst().joined(separator: "] ")
        return afterTime.components(separatedBy: ":").first ?? ""
    }
    static func capitalised(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// "milk and bread" / "eggs, butter and jam" -> separate items.
    static func splitItems(_ s: String) -> [String] {
        Rx(#"\s*,\s*|\s+and\s+|\s*&\s*"#).split(s).map { piece in
            var t = piece.trimmingCharacters(in: .whitespaces)
            for p in ["some ", "more "] where t.hasPrefix(p) { t.removeFirst(p.count) }
            return t
        }.filter { !$0.isEmpty }
    }

    /// Actions found by rules alone. [title] names an agreed plan with no clear noun.
    /// [youOnly] keeps to-dos to lines by "You" (the Android app knows voices); with no voices
    /// to go on, every line counts.
    public static func ruleActions(_ lines: [String], conversationStart: Date, title: String?, calendar: Calendar = .current, youOnly: Bool = true) -> [ExtractedAction] {
        var out: [ExtractedAction] = []
        for (index, line) in lines.enumerated() {
            let t = text(line)
            let next = index + 1 < lines.count ? text(lines[index + 1]) : ""
            // Clause by clause, so "go to the pub and then get some milk" still finds the milk.
            for clause in clauses.split(t) where !eatingOut.test(clause) && !collecting.test(clause) {
                for (r, rule) in buyRules.enumerated() {
                    for m in rule.all(clause) {
                        // "pick up Ezra": a name with no "some" or "the" before it is someone.
                        if r == 1, isCollecting(m[1], in: [clause]) { continue }
                        for it in splitItems(m[1]) where it.count >= 2 && it.count <= 40 &&
                            !it.split(separator: " ").contains(where: { notItems.contains($0.lowercased()) }) {
                            out.append(ExtractedAction(type: .buy, title: capitalised(it), source: line))
                        }
                    }
                }
            }
            if !youOnly || speaker(line) == "You", let m = todoRule.first(t) {
                var task = m[1].trimmingCharacters(in: .whitespaces)
                for p in ["also ", "just "] where task.hasPrefix(p) { task.removeFirst(p.count) }
                // "Tom, I'll send you that link" -> "send Tom that link"
                if let v = Rx(#"^([A-Z][a-z]+),"#, caseSensitive: true).first(t) {
                    task = Rx(#"\byou\b"#, caseSensitive: true).replace(task, with: v[1])
                }
                task = specific(task, in: t)
                if !buyRules.contains(where: { $0.test("I'll " + task) }) && !vagueTask.test(task) {
                    out.append(ExtractedAction(type: .todo, title: capitalised(task), source: line))
                }
            }
            // Sentence by sentence: the date that goes with "dentist" is in its own sentence or
            // the next ("What about your dentist? Isn't that next Tuesday?"), not anywhere on the
            // line ("I'll order it tonight" earlier must not make it tonight).
            let sentences = Rx(#"(?<=[.?!])\s+"#).split(t)
            for (i, sentence) in sentences.enumerated() {
                let noun = eventNoun.first(sentence)
                // "after dinner tonight" is when, not a dinner to go to.
                if noun != nil, Rx(#"\b(after|before|during|over|with)\s+(dinner|lunch|tea|breakfast|drinks)\b"#).test(sentence) { continue }
                // The date that follows the thing first ("dentist? ... next Tuesday"), then anything before it
                // ("do it tonight or you'll forget what about your dentist" must not be tonight).
                var candidates: [String] = []
                if let noun, let r = sentence.lowercased().range(of: noun[2]) {
                    candidates.append(String(sentence[r.lowerBound...]))
                }
                if noun != nil, i + 1 < sentences.count, !eventNoun.test(sentences[i + 1]) { candidates.append(sentences[i + 1]) }
                candidates.append(sentence)
                guard let (said, resolved) = candidates.lazy.compactMap({ c in
                    WhenParser.parse(c, reference: conversationStart, calendar: calendar).map { (c, $0) }
                }).first else { continue }
                // "He turned five today": happening already, not one for the calendar.
                if happeningToday(resolved, conversationStart: conversationStart, calendar: calendar) { continue }
                let dateSentence = sentences.first { $0.contains(said) || said.contains($0) } ?? sentence
                let note = planNote(resolved, said: dateSentence, around: sentences[i...].joined(separator: " ") + " " + next, thing: sentence)
                if let noun {
                    let name = (noun[1] + " " + noun[2]).trimmingCharacters(in: .whitespaces)
                    out.append(ExtractedAction(type: .event, title: capitalised(name), whenText: said, resolved: resolved, note: note, source: line))
                } else if let title, resolved.hour != nil, agreed.test(sentence) {
                    out.append(ExtractedAction(type: .event, title: title, whenText: said, resolved: resolved, note: note, source: line))
                }
            }
        }
        return out
    }

    /// The AI's findings, tidied: shopping filed as a task becomes shopping; lists split up.
    /// [booked]: the AI's view that the plan was booked or confirmed, not just suggested. [lines]:
    /// what it read, to find where each item came from.
    public static func fromModel(buy: [String], todo: [String], events: [(what: String, when: String?, place: String?, booked: Bool)],
                                 conversationStart: Date, lines: [String] = [], calendar: Calendar = .current) -> [ExtractedAction] {
        var out: [ExtractedAction] = []
        // With the lines it read, everything it found is checked against them: small models
        // add things of their own ("Confirm McDonald's details"), and "pick up Ezra" isn't shopping.
        let checking = !lines.isEmpty
        func buyable(_ it: String) -> Bool {
            !checking || (grounded(it, in: lines) && !isCollecting(it, in: lines))
        }
        for b in buy { for it in splitItems(b) where buyable(it) { out.append(ExtractedAction(type: .buy, title: String(capitalised(it).prefix(60)))) } }
        for t in todo {
            let task = t.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.isEmpty, !checking || grounded(task, in: lines) else { continue }
            if let m = buyTodo.whole(task), !notShopping.test(task) {
                for it in splitItems(m[1]) where buyable(it) { out.append(ExtractedAction(type: .buy, title: String(capitalised(it).prefix(60)))) }
            } else {
                out.append(ExtractedAction(type: .todo, title: String(capitalised(task).prefix(100))))
            }
        }
        for e in events where !e.what.isEmpty && !bogusEventTitle.test(e.what.lowercased()) {
            // Only real plans: a day or a time actually said ("Thursday at 3"), not "later" or "nothing".
            guard let whenText = e.when.flatMap({ $0.isEmpty ? nil : $0 }), !vagueWhen.test(whenText.lowercased()),
                  let resolved = WhenParser.parse(whenText, reference: conversationStart, calendar: calendar) else { continue }
            // Today with no time: it's happening, not something to put in the calendar.
            if happeningToday(resolved, conversationStart: conversationStart, calendar: calendar) { continue }
            // The day (or time) has to have been said about it, not assumed: in the line that
            // mentions it, or the one after.
            if checking {
                let near = lines.indices.filter { overlap(e.what, said(lines[$0])) > 0 }.flatMap { [$0, $0 + 1] }.filter { $0 < lines.count }
                let sameDay = near.contains { i in
                    guard let r = WhenParser.parse(said(lines[i]), reference: conversationStart, calendar: calendar) else { return false }
                    return r.year == resolved.year && r.month == resolved.month && r.day == resolved.day
                }
                guard sameDay else { continue }
            }
            let source = sourceLine(e.what + " " + whenText, in: lines)
            var note = resolved.doubt
            let thing = e.what + " " + (source.map(said) ?? "")
            if note == nil, let source {
                let i = lines.firstIndex(of: source)!
                let around = said(source) + " " + (i + 1 < lines.count ? said(lines[i + 1]) : "")
                note = planNote(resolved, said: whenText, around: around, thing: thing)
            }
            if note == nil, !e.booked, bookable.test(thing) { note = "Not booked yet" }
            out.append(ExtractedAction(
                type: .event, title: String(capitalised(e.what).prefix(80)), whenText: whenText,
                place: e.place.flatMap { $0.isEmpty ? nil : $0 }, resolved: resolved, note: note, source: source))
        }
        for i in out.indices where out[i].source == nil { out[i].source = sourceLine(out[i].title, in: lines) }
        return out
    }

    static let stop: Set<String> = ["the", "a", "an", "to", "for", "of", "and", "some", "my", "your", "with", "on", "at", "by", "tonight", "tomorrow", "today"]
    public static func words(_ s: String) -> Set<String> {
        Set(Rx(#"[a-z0-9']+"#).all(s.lowercased()).map { w in
            var x = w[0]
            if x.hasSuffix("s") { x.removeLast() }
            return x
        }.filter { !stop.contains($0) })
    }

    /// How many words two pieces of text share.
    public static func overlap(_ a: String, _ b: String) -> Int { words(a).intersection(words(b)).count }

    /// Mostly the same words: "Milk" and "some milk", "Send Tom the link" and "send the link to Tom".
    /// Not "Dentist appointment" and "Doctor's appointment", or "Milk" and "Milk chocolate": two
    /// thirds of the longer one's words in common.
    public static func similar(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard !x.isEmpty, !y.isEmpty else { return false }
        return Double(x.intersection(y).count) / Double(max(x.count, y.count)) >= 0.67
    }

    /// The AI's findings plus the rules', de-duplicated (the AI's wording wins).
    public static func merge(_ model: [ExtractedAction], _ rules: [ExtractedAction]) -> [ExtractedAction] {
        var kept = model.filter { a in
            !(a.type == .event && (bogusEventTitle.test(a.title) || (a.whenText.map(vagueWhen.test) ?? false)))
        }
        for r in rules {
            if let i = kept.firstIndex(where: { $0.type == r.type && similar($0.title, r.title) }) {
                if kept[i].source == nil { kept[i].source = r.source }
                if r.resolved?.doubt != nil { kept[i].note = r.note }
            }
            let dup = kept.contains { k in
                if r.type == .buy, k.type != .buy, k.source != nil, k.source == r.source, overlap(k.title, r.title) > 0 { return true }
                if k.type == .event && r.type == .event {
                    let sameDay = k.resolved.map { [$0.year, $0.month, $0.day] } == r.resolved.map { [$0.year, $0.month, $0.day] } && k.resolved != nil
                    return sameDay || similar(k.title, r.title)
                }
                return (k.type == r.type && similar(k.title, r.title)) || (r.type == .buy && k.type == .todo && similar(k.title, r.title))
            }
            if !dup { kept.append(r) }
        }
        var seen = Set<String>()
        return kept.filter { seen.insert($0.type.rawValue + "|" + $0.title.lowercased()).inserted }
    }
}
