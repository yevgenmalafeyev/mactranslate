import CryptoKit
import Foundation
import NaturalLanguage

public struct WordToken: Hashable, Sendable {
    public let text: String
    /// UTF-16 offsets into the snippet.
    public let start: Int
    public let end: Int
}

public enum TextTools {
    public static func normalize(_ s: String) -> String {
        var t = s.precomposedStringWithCanonicalMapping
        // Control characters other than line break and tab never belong to text to translate.
        t = t.replacingOccurrences(of: "[\\p{Cc}&&[^\\n\\r\\t]]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\r\n", with: "\n")
        t = t.replacingOccurrences(of: "[ \\t\\u00A0]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: " *\\n *", with: "\n", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func hash(_ normalized: String) -> String {
        SHA256.hash(data: Data(normalized.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    public static func words(in text: String) -> [WordToken] {
        let tok = NLTokenizer(unit: .word)
        tok.string = text
        var out: [WordToken] = []
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let w = String(text[r])
            if w.contains(where: { $0.isLetter }) {
                let ns = NSRange(r, in: text)
                out.append(WordToken(text: w, start: ns.location, end: ns.location + ns.length))
            }
            return true
        }
        return out
    }

    /// The sentence containing the UTF-16 offset, capped at `limit` characters.
    public static func sentence(in text: String, around offset: Int, limit: Int = 300) -> String {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var found = text
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let ns = NSRange(r, in: text)
            if offset >= ns.location && offset < ns.location + ns.length {
                found = String(text[r])
                return false
            }
            return true
        }
        let s = found.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.count > limit ? String(s.prefix(limit)) : s
    }

    /// The sentence containing the word at UTF-16 range [start, end), with that occurrence wrapped in ⟦ ⟧.
    public static func markedSentence(in text: String, start: Int, end: Int, limit: Int = 300) -> String {
        let ns = text as NSString
        guard start >= 0, end <= ns.length, start < end else { return sentence(in: text, around: max(0, start), limit: limit) }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        var range = NSRange(location: 0, length: ns.length)
        tok.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let nr = NSRange(r, in: text)
            if start >= nr.location && start < nr.location + nr.length { range = nr; return false }
            return true
        }
        // Keep the window around the word if the sentence is very long.
        if range.length > limit {
            let lo = max(range.location, start - limit / 2)
            range = NSRange(location: lo, length: min(limit, range.location + range.length - lo))
        }
        let before = ns.substring(with: NSRange(location: range.location, length: start - range.location))
        let word = ns.substring(with: NSRange(location: start, length: end - start))
        let afterLen = max(0, range.location + range.length - end)
        let after = ns.substring(with: NSRange(location: end, length: afterLen))
        return (before + "⟦" + word + "⟧" + after).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Local language guess (ISO 639-1) with confidence, biased toward `hints`.
    public static func guessLanguage(_ text: String, hints: [String]) -> (code: String, confidence: Double)? {
        let r = NLLanguageRecognizer()
        var h: [NLLanguage: Double] = [:]
        for code in hints { h[NLLanguage(rawValue: code)] = 1.0 / Double(max(hints.count, 1)) }
        if !h.isEmpty { r.languageHints = h }
        r.processString(text)
        guard let (lang, conf) = r.languageHypotheses(withMaximum: 1).first else { return nil }
        let code = String(lang.rawValue.split(separator: "-").first ?? "")
        return code.isEmpty ? nil : (code, conf)
    }
}
