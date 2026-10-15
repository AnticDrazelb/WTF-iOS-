import Foundation

/// A compiled regular expression with the few operations WTF needs (Foundation's, so it's
/// the same on iOS and Linux). Case-insensitive unless asked otherwise.
public struct Rx: @unchecked Sendable {
    let re: NSRegularExpression

    public init(_ pattern: String, caseSensitive: Bool = false) {
        // swiftlint:disable:next force_try
        re = try! NSRegularExpression(pattern: pattern, options: caseSensitive ? [] : [.caseInsensitive])
    }

    private func range(_ s: String) -> NSRange { NSRange(s.startIndex..., in: s) }

    public func test(_ s: String) -> Bool { re.firstMatch(in: s, range: range(s)) != nil }

    /// Groups of the first match: [whole, group 1, …]; a group that didn't take part is "".
    public func first(_ s: String) -> [String]? {
        re.firstMatch(in: s, range: range(s)).map { groups($0, in: s) }
    }

    public func all(_ s: String) -> [[String]] {
        re.matches(in: s, range: range(s)).map { groups($0, in: s) }
    }

    /// Groups if the whole string matches.
    public func whole(_ s: String) -> [String]? {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: range(s)), m.range.length == (s as NSString).length else { return nil }
        return groups(m, in: s)
    }

    public func replace(_ s: String, with template: String) -> String {
        re.stringByReplacingMatches(in: s, range: range(s), withTemplate: template)
    }

    public func split(_ s: String) -> [String] {
        var out: [String] = []
        var last = s.startIndex
        for m in re.matches(in: s, range: range(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            out.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        out.append(String(s[last...]))
        return out
    }

    private func groups(_ m: NSTextCheckingResult, in s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
}
