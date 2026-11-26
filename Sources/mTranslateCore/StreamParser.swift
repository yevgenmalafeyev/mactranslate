import Foundation

/// Incremental parser for the translation / monolingual tab output:
///
///     LANG: en
///     <translation text...>
///     @@WORDS@@
///     {"w":...}
///     {"w":...}
///
/// or `LANG: xx\n@@SAME@@` when the target equals the source.
public struct SnippetStreamParser: Sendable {
    public enum Event: Equatable, Sendable {
        case language(String)
        case translationDelta(String)
        case sameLanguage
        case word(WordEntry)
    }

    enum State { case header, translation, words, done }

    static let wordsMark = "@@WORDS@@"
    static let sameMark = "@@SAME@@"
    static let holdPrefixes = ["\n@@WORDS@@", "\n@@SAME@@", "@@WORDS@@", "@@SAME@@"]

    var state: State = .header
    var buffer = ""
    public private(set) var language: String?
    public private(set) var translation = ""
    public private(set) var words: [WordEntry] = []
    public private(set) var isSame = false
    public private(set) var badLines = 0

    public init() {}

    public var cleanTranslation: String {
        translation.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk.replacingOccurrences(of: "\r", with: "")
        return process(final: false)
    }

    public mutating func finish() -> [Event] {
        process(final: true)
    }

    /// Parse a complete text in one go.
    public static func parse(_ full: String) -> SnippetStreamParser {
        var p = SnippetStreamParser()
        _ = p.feed(full)
        _ = p.finish()
        return p
    }

    private mutating func process(final: Bool) -> [Event] {
        var out: [Event] = []
        var progressed = true
        while progressed {
            progressed = false
            switch state {
            case .header:
                if let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl]).trimmingCharacters(in: .whitespaces)
                    if line.isEmpty || line.hasPrefix("```") {
                        buffer.removeSubrange(...nl)
                        progressed = true
                    } else if let code = Self.langCode(line) {
                        language = code
                        out.append(.language(code))
                        buffer.removeSubrange(...nl)
                        state = .translation
                        progressed = true
                    } else {
                        state = .translation
                        progressed = true
                    }
                } else if final {
                    let line = buffer.trimmingCharacters(in: .whitespaces)
                    if let code = Self.langCode(line) {
                        language = code
                        out.append(.language(code))
                        buffer = ""
                    }
                    state = .translation
                    progressed = true
                } else if buffer.count > 24, !buffer.hasPrefix("LANG"), !buffer.hasPrefix("`") {
                    state = .translation
                    progressed = true
                }
            case .translation:
                let w = buffer.range(of: Self.wordsMark)
                let s = buffer.range(of: Self.sameMark)
                if let r = [w, s].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
                    var before = String(buffer[..<r.lowerBound])
                    while before.last?.isNewline == true || before.last == " " { before.removeLast() }
                    if !before.isEmpty { translation += before; out.append(.translationDelta(before)) }
                    let isSameMark = (r == s)
                    buffer = String(buffer[r.upperBound...])
                    if isSameMark {
                        isSame = true
                        out.append(.sameLanguage)
                        buffer = ""
                        state = .done
                    } else {
                        state = .words
                    }
                    progressed = true
                } else {
                    let hold = final ? 0 : Self.holdBack(buffer)
                    var emit = String(buffer.dropLast(hold))
                    if final {
                        while emit.last?.isNewline == true || emit.last == " " { emit.removeLast() }
                        if emit.hasSuffix("```") { emit.removeLast(3) }
                    }
                    if !emit.isEmpty {
                        translation += emit
                        out.append(.translationDelta(emit))
                    }
                    buffer = String(buffer.suffix(hold))
                    if final { state = .done }
                }
            case .words:
                while let nl = buffer.firstIndex(of: "\n") {
                    let line = String(buffer[..<nl])
                    buffer.removeSubrange(...nl)
                    if let e = parseWordLine(line) { out.append(e) }
                }
                if final {
                    if let e = parseWordLine(buffer) { out.append(e) }
                    buffer = ""
                    state = .done
                }
            case .done:
                break
            }
        }
        return out
    }

    private mutating func parseWordLine(_ raw: String) -> Event? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("```") || line == "[" || line == "]" { return nil }
        if line.hasSuffix(",") { line.removeLast() }
        if line.hasPrefix("[") { line.removeFirst() }
        if line.hasSuffix("]"), !line.hasSuffix("\"]"), line.hasSuffix("}]") { line.removeLast() }
        guard let data = line.data(using: .utf8),
              let entry = try? JSONDecoder().decode(WordEntry.self, from: data)
        else { badLines += 1; return nil }
        if words.contains(where: { $0.l.lowercased() == entry.l.lowercased() }) { return nil }
        words.append(entry)
        return .word(entry)
    }

    static func langCode(_ line: String) -> String? {
        guard line.uppercased().hasPrefix("LANG:") else { return nil }
        let code = line.dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased()
        let ok = (2...8).contains(code.count) && code.allSatisfy { $0.isLetter || $0 == "-" }
        return ok ? code : nil
    }

    /// Length of the longest buffer suffix that could be the start of a delimiter.
    static func holdBack(_ s: String) -> Int {
        let maxLen = holdPrefixes.map(\.count).max() ?? 0
        for k in stride(from: min(maxLen, s.count), to: 0, by: -1) {
            let suf = String(s.suffix(k))
            if holdPrefixes.contains(where: { $0.hasPrefix(suf) }) { return k }
        }
        return 0
    }
}

/// Incremental JSON-Lines parser for word cards.
public struct CardStreamParser: Sendable {
    public enum Event: Sendable {
        case head(CardHeader)
        case sense(CardSense)
    }

    var buffer = ""
    public private(set) var head: CardHeader?
    public private(set) var senses: [CardSense] = []
    public private(set) var badLines = 0

    public init() {}

    public var card: WordCard? { head.map { WordCard(head: $0, senses: senses) } }

    public mutating func feed(_ chunk: String) -> [Event] {
        buffer += chunk.replacingOccurrences(of: "\r", with: "")
        var out: [Event] = []
        while let nl = buffer.firstIndex(of: "\n") {
            let line = String(buffer[..<nl])
            buffer.removeSubrange(...nl)
            if let e = parseLine(line) { out.append(e) }
        }
        return out
    }

    public mutating func finish() -> [Event] {
        let rest = buffer
        buffer = ""
        return parseLine(rest).map { [$0] } ?? []
    }

    public static func parse(_ full: String) -> CardStreamParser {
        var p = CardStreamParser()
        _ = p.feed(full)
        _ = p.finish()
        return p
    }

    private mutating func parseLine(_ raw: String) -> Event? {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.isEmpty || line.hasPrefix("```") || line == "[" || line == "]" { return nil }
        if line.hasSuffix(",") { line.removeLast() }
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let t = obj["t"] as? String
        else { badLines += 1; return nil }
        let dec = JSONDecoder()
        switch t {
        case "head":
            guard head == nil, let h = try? dec.decode(CardHeader.self, from: data) else { badLines += 1; return nil }
            head = h
            return .head(h)
        case "sense":
            guard let s = try? dec.decode(CardSense.self, from: data) else { badLines += 1; return nil }
            senses.append(s)
            return .sense(s)
        default:
            return nil
        }
    }
}
