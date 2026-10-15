import Foundation

/// A resolved date and, if one was said, a time of day.
public struct WhenResult: Equatable, Sendable {
    public var year: Int, month: Int, day: Int
    public var hour: Int?, minute: Int?
    /// Set when what was said doesn't add up, e.g. "Saturday the 1st" when the 1st is a Sunday.
    /// The date itself is kept (it's the firmer anchor); this says what to check.
    public var doubt: String?

    public var allDay: Bool { hour == nil }

    /// The moment it starts (midnight for an all-day event) in [calendar]'s time zone.
    public func start(in calendar: Calendar = .current) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour ?? 0, minute: minute ?? 0))!
    }
}

/// Turns spoken date/time phrases ("Thursday at half two", "tomorrow 9am", "the 24th",
/// "next Tuesday evening") into a real date, relative to when the conversation happened.
/// Done in code because small models are bad at date arithmetic. Returns nil if no date
/// can be worked out. (Ported from the Android app's WhenParser; same tests.)
public enum WhenParser {
    static let numbers = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                          "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12]
    static let ordinals: [(String, Int)] = [
        ("first", 1), ("second", 2), ("third", 3), ("fourth", 4), ("fifth", 5), ("sixth", 6), ("seventh", 7),
        ("eighth", 8), ("ninth", 9), ("tenth", 10), ("eleventh", 11), ("twelfth", 12), ("thirteenth", 13),
        ("fourteenth", 14), ("fifteenth", 15), ("sixteenth", 16), ("seventeenth", 17), ("eighteenth", 18),
        ("nineteenth", 19), ("twentieth", 20), ("thirtieth", 30),
    ]
    /// Weekday numbers as Calendar uses them: Sunday = 1 … Saturday = 7.
    static let days = ["sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7]
    static let months: [String: Int] = {
        let names = ["january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december"]
        var m: [String: Int] = [:]
        for (i, n) in names.enumerated() { m[n] = i + 1; m[String(n.prefix(3))] = i + 1 }
        m["sept"] = 9
        return m
    }()

    static var gregorian: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private struct Day: Comparable {
        var y: Int, m: Int, d: Int
        static func < (a: Day, b: Day) -> Bool { (a.y, a.m, a.d) < (b.y, b.m, b.d) }
        var date: Date { WhenParser.gregorian.date(from: DateComponents(year: y, month: m, day: d))! }
        init(y: Int, m: Int, d: Int) { self.y = y; self.m = m; self.d = d }
        init(_ date: Date) {
            let c = WhenParser.gregorian.dateComponents([.year, .month, .day], from: date)
            self.init(y: c.year!, m: c.month!, d: c.day!)
        }
        func plus(days n: Int) -> Day { Day(WhenParser.gregorian.date(byAdding: .day, value: n, to: date)!) }
        var weekday: Int { WhenParser.gregorian.component(.weekday, from: date) }
        /// The next [weekday] strictly after this day (or this day itself if [orSame]).
        func next(_ weekday: Int, orSame: Bool = false) -> Day {
            var gap = (weekday - self.weekday + 7) % 7
            if gap == 0 && !orSame { gap = 7 }
            return plus(days: gap)
        }
        static func daysIn(_ y: Int, _ m: Int) -> Int {
            WhenParser.gregorian.range(of: .day, in: .month, for: Day(y: y, m: m, d: 1).date)!.count
        }
    }

    /// [reference]'s wall-clock fields matter, not its zone: pass the conversation's local time.
    public static func parse(_ phrase: String, reference: DateComponents) -> WhenResult? {
        var q = phrase.lowercased()
        q = Rx(#"(\d)(st|nd|rd|th)\b"#).replace(q, with: "$1")
        q = q.replacingOccurrences(of: "a.m.", with: "am").replacingOccurrences(of: "p.m.", with: "pm").replacingOccurrences(of: "o'clock", with: "")
        q = " " + Rx(#"[,.!?]"#).replace(q, with: " ") + " "
        let today = Day(y: reference.year!, m: reference.month!, d: reference.day!)
        guard var date = parseDate(q, today: today) else { return nil }
        // "Saturday the 1st": the date is the anchor; if its weekday isn't the one said, say so.
        var doubt: String?
        let weekday = Rx(#"\b(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#).first(q)
        if let weekday {
            let rest = Rx(#"\b(next|this|on)?\s*(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#).replace(q, with: " ")
            if explicitDate.test(rest), let anchored = parseDate(rest, today: today) {
                date = anchored
                if anchored.weekday != days[weekday[1]]! {
                    doubt = "You said \(weekday[1].capitalized) the \(ordinal(anchored.d)), but \(anchored.d) \(monthName(anchored.m)) \(anchored.y) is a \(dayName(anchored.weekday))"
                }
            }
        }
        var time = parseTime(q)
        // A bare "today at 3" that's already passed this morning is probably pm.
        if let t = time, date == today, (t.0 * 60 + t.1) < ((reference.hour ?? 0) * 60 + (reference.minute ?? 0)), t.0 < 12,
           !Rx(#"\bam\b|morning"#).test(q) {
            time = (t.0 + 12, t.1)
        }
        return WhenResult(year: date.y, month: date.m, day: date.d, hour: time?.0, minute: time?.1, doubt: doubt)
    }

    /// A day of the month or a month named: "the 1st", "2 November", "November 2", "5/11".
    static let explicitDate: Rx = {
        let monthNames = "january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec"
        let ords = ordinals.map(\.0).joined(separator: "|")
        return Rx(#"\bthe\s+(\d{1,2}|(twenty[ -])?("# + ords + #"))\b|\b\d{1,2}\s+(of\s+)?("# + monthNames + #")\b|\b("# + monthNames + #")\s+\d{1,2}\b|\b\d{1,2}/\d{1,2}\b"#)
    }()

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : [1: "st", 2: "nd", 3: "rd"][n % 10] ?? "th"
        return "\(n)\(suffix)"
    }
    static func monthName(_ m: Int) -> String {
        ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"][m - 1]
    }
    static func dayName(_ weekday: Int) -> String {
        ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][weekday - 1]
    }

    public static func parse(_ phrase: String, reference: Date, calendar: Calendar = .current) -> WhenResult? {
        parse(phrase, reference: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reference))
    }

    private static func parseDate(_ q: String, today: Day) -> Day? {
        if Rx(#"\bday after tomorrow\b"#).test(q) { return today.plus(days: 2) }
        if Rx(#"\b(tomorrow|tmrw)\b"#).test(q) { return today.plus(days: 1) }
        if Rx(#"\b(today|tonight|this (morning|afternoon|evening))\b"#).test(q) { return today }

        // "24 October", "October 24", "24/10"
        for m in Rx(#"\b(\d{1,2})\s+(?:of\s+)?([a-z]+)\b"#).all(q) {
            if let month = months[m[2]] { return nextDate(today, month: month, day: Int(m[1])!) }
        }
        for m in Rx(#"\b([a-z]+)\s+(\d{1,2})\b"#).all(q) {
            if let month = months[m[1]] { return nextDate(today, month: month, day: Int(m[2])!) }
        }
        if let m = Rx(#"\b(\d{1,2})/(\d{1,2})\b"#).first(q), let month = Int(m[2]), (1...12).contains(month) {
            return nextDate(today, month: month, day: Int(m[1])!) // UK order
        }

        // Weekdays: "Thursday" = the next one; "next Thursday" = the one in the following week.
        if let m = Rx(#"\b(next|this|on)?\s*(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#).first(q) {
            var d = today.next(days[m[2]]!)
            if m[1] == "next" && d < today.next(2) { d = d.plus(days: 7) }
            return d
        }
        if Rx(#"\b(this )?weekend\b"#).test(q) { return today.next(7, orSame: true) }
        if Rx(#"\bnext week\b"#).test(q) { return today.next(2) }

        // "the 24th" / "on the twentieth": this month, or next if it's passed.
        var dayOfMonth: Int? = Rx(#"\bthe\s+(\d{1,2})\b"#).first(q).flatMap { Int($0[1]) }
        if dayOfMonth == nil {
            for (w, n) in ordinals where Rx(#"\bthe\s+(twenty |twenty-)?"# + w + #"\b"#).test(q) {
                dayOfMonth = Rx("twenty[ -]" + w).test(q) ? 20 + n : n
                break
            }
        }
        if let dom = dayOfMonth, (1...31).contains(dom) {
            var y = today.y, m = today.m
            for _ in 0..<13 {
                if dom <= Day.daysIn(y, m) {
                    let candidate = Day(y: y, m: m, d: dom)
                    if !(candidate < today) { return candidate }
                }
                m += 1
                if m > 12 { m = 1; y += 1 }
            }
        }
        return nil
    }

    private static func nextDate(_ today: Day, month: Int, day: Int) -> Day? {
        for year in today.y...(today.y + 1) {
            guard (1...Day.daysIn(year, month)).contains(day) else { return nil }
            let d = Day(y: year, m: month, d: day)
            if !(d < today) { return d }
        }
        return nil
    }

    private static func parseTime(_ q: String) -> (Int, Int)? {
        let num = #"(\d{1,2}|"# + numbers.keys.sorted { $0.count > $1.count }.joined(separator: "|") + ")"
        func n(_ s: String) -> Int { Int(s) ?? numbers[s]! }
        let pm = Rx(#"\bpm\b|afternoon|evening|tonight|night"#).test(q)
        let am = Rx(#"\bam\b|morning"#).test(q)
        func adjust(_ h: Int) -> Int {
            if h == 12 { return am && !pm ? 0 : 12 }
            if pm && h < 12 { return h + 12 }
            if am { return h }
            if (1...7).contains(h) { return h + 12 } // "at 3" almost always means 3pm
            return h
        }
        if Rx(#"\b(noon|midday|lunchtime)\b"#).test(q) { return (12, 0) }
        if Rx(#"\bmidnight\b"#).test(q) { return (0, 0) }
        if let m = Rx(#"\b(\d{1,2})[:.](\d{2})\s*(am|pm)?\b"#).first(q) {
            return (adjust(Int(m[1])!) % 24, min(max(Int(m[2])!, 0), 59))
        }
        if let m = Rx(#"\bhalf (past )?"# + num + #"\b"#).first(q) { return (adjust(n(m[2])) % 24, 30) }
        if let m = Rx(#"\bquarter past "# + num + #"\b"#).first(q) { return (adjust(n(m[1])) % 24, 15) }
        if let m = Rx(#"\bquarter to "# + num + #"\b"#).first(q) { return ((adjust(n(m[1])) + 23) % 24, 45) }
        if let m = Rx(#"\b"# + num + #"\s*(am|pm)\b"#).first(q) { return (adjust(n(m[1])) % 24, 0) }
        if let m = Rx(#"\b(?:at|for|from|by)\s+"# + num + #"\b(?!\s*(?:st|nd|rd|th|minutes|mins|people|of))"#).first(q) {
            let h = n(m[1])
            if (1...12).contains(h) { return (adjust(h) % 24, 0) }
        }
        return nil
    }
}
