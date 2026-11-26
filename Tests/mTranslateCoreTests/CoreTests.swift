import XCTest
@testable import mTranslateCore

final class StreamParserTests: XCTestCase {
    let sample = "LANG: en\nБыстрая лиса.\nВторая строка.\n@@WORDS@@\n{\"w\":\"lazy\",\"l\":\"lazy\",\"p\":\"adj\",\"m\":[\"ленивый\",\"вялый\"]}\n{\"w\":\"jumps\",\"l\":\"jump\",\"p\":\"v\",\"m\":[\"прыгать\"]}\n"

    func testWhole() {
        let p = SnippetStreamParser.parse(sample)
        XCTAssertEqual(p.language, "en")
        XCTAssertEqual(p.cleanTranslation, "Быстрая лиса.\nВторая строка.")
        XCTAssertEqual(p.words.map(\.l), ["lazy", "jump"])
        XCTAssertEqual(p.badLines, 0)
    }

    func testSplitAtEveryOffset() {
        let chars = Array(sample)
        for cut in 1..<chars.count {
            var p = SnippetStreamParser()
            var emitted = ""
            for e in p.feed(String(chars[..<cut])) + p.feed(String(chars[cut...])) + p.finish() {
                if case .translationDelta(let d) = e { emitted += d }
            }
            XCTAssertEqual(p.language, "en", "cut \(cut)")
            XCTAssertEqual(emitted.trimmingCharacters(in: .whitespacesAndNewlines), "Быстрая лиса.\nВторая строка.", "cut \(cut)")
            XCTAssertFalse(emitted.contains("@"), "cut \(cut)")
            XCTAssertEqual(p.words.count, 2, "cut \(cut)")
        }
    }

    func testCharByChar() {
        var p = SnippetStreamParser()
        var emitted = ""
        for c in sample { for e in p.feed(String(c)) { if case .translationDelta(let d) = e { emitted += d } } }
        _ = p.finish()
        XCTAssertEqual(emitted, "Быстрая лиса.\nВторая строка.")
        XCTAssertEqual(p.words.count, 2)
    }

    func testSame() {
        let p = SnippetStreamParser.parse("LANG: ru\n@@SAME@@\n")
        XCTAssertTrue(p.isSame)
        XCTAssertEqual(p.language, "ru")
        XCTAssertEqual(p.cleanTranslation, "")
    }

    func testMissingHeaderAndFencesAndBadLine() {
        let p = SnippetStreamParser.parse("Привет мир\n@@WORDS@@\n```json\n{bad}\n{\"w\":\"x\",\"l\":\"x\",\"p\":\"n\",\"m\":[\"a\"]},\n```")
        XCTAssertNil(p.language)
        XCTAssertEqual(p.cleanTranslation, "Привет мир")
        XCTAssertEqual(p.words.count, 1)
        XCTAssertEqual(p.badLines, 1)
    }

    func testCRLF() {
        let p = SnippetStreamParser.parse("LANG: de\r\nHallo\r\n@@WORDS@@\r\n{\"w\":\"x\",\"l\":\"x\",\"p\":\"n\",\"m\":[\"a\"]}\r\n")
        XCTAssertEqual(p.language, "de")
        XCTAssertEqual(p.cleanTranslation, "Hallo")
        XCTAssertEqual(p.words.count, 1)
    }

    func testNoWords() {
        let p = SnippetStreamParser.parse("LANG: en\nПривет\n@@WORDS@@\n")
        XCTAssertEqual(p.cleanTranslation, "Привет")
        XCTAssertTrue(p.words.isEmpty)
    }

    func testCard() {
        let s = """
        {"t":"head","lemma":"comboio","pos":"сущ.","gender":"m","ipa":"kõˈbɔju","forms":"pl. comboios","note":""}
        {"t":"sense","gloss":"поезд","tr":["поезд"],"def":"...","ex":[{"s":"O comboio parte.","t":"Поезд уходит."}],"img":"passenger train","wiki":"Train","abstract":false}
        {"t":"sense","gloss":"колонна","tr":["колонна"],"def":"...","ex":[],"img":"convoy of trucks","wiki":"","abstract":false}
        """
        let p = CardStreamParser.parse(s)
        XCTAssertEqual(p.head?.lemma, "comboio")
        XCTAssertEqual(p.senses.count, 2)
        XCTAssertEqual(p.card?.senses.first?.ex.first?.t, "Поезд уходит.")
    }
}

final class TabPlanTests: XCTestCase {
    let enabled = ["uk", "ru", "pt-PT", "en", "de"].compactMap(LanguageRegistry.byId)

    func testUkrainianSource() {
        let tabs = TabPlan.tabs(enabled: enabled, source: LanguageRegistry.forCode("uk"))
        XCTAssertEqual(tabs.map(\.id), ["ru", "pt-PT", "en", "de", "mono:uk"])
        XCTAssertEqual(TabPlan.initial(tabs: tabs, defaultId: "uk", secondId: "ru")?.id, "ru")
    }

    func testBrazilianSourceMapsToPT() {
        let tabs = TabPlan.tabs(enabled: enabled, source: LanguageRegistry.forCode("pt-BR"))
        XCTAssertEqual(tabs.map(\.id), ["uk", "ru", "en", "de", "mono:pt-PT"])
    }

    func testFrenchSource() {
        let tabs = TabPlan.tabs(enabled: enabled, source: LanguageRegistry.forCode("fr"))
        XCTAssertEqual(tabs.count, 6)
        XCTAssertEqual(tabs.last?.id, "mono:fr")
        XCTAssertEqual(TabPlan.initial(tabs: tabs, defaultId: "uk", secondId: "ru")?.id, "uk")
    }
}

final class StoreTests: XCTestCase {
    func testRoundTrip() async throws {
        let path = NSTemporaryDirectory() + "mt-\(UUID().uuidString).sqlite"
        let s = try Store(path: path)
        let text = "Привіт, як справи?"
        let (id, src) = try await s.touchSnippet(hash: TextTools.hash(text), text: text)
        XCTAssertNil(src)
        try await s.setSourceLang(snippetId: id, lang: "uk")
        let again = try await s.touchSnippet(hash: TextTools.hash(text), text: text)
        XCTAssertEqual(again.id, id)
        XCTAssertEqual(again.sourceLang, "uk")
        try await s.saveTranslation(snippetId: id, target: "ru", level: "B2", model: "sonnet", translation: "Привет",
                                    words: [WordEntry(w: "справи", l: "справа", p: "n", m: ["дела"])])
        let t = try await s.translation(snippetId: id, target: "ru", level: "B2")
        XCTAssertEqual(t?.words.first?.l, "справа")
        let none = try await s.translation(snippetId: id, target: "ru", level: "C1")
        XCTAssertNil(none)
        let found = try await s.recentSnippets(search: "ПРИВІТ")
        XCTAssertEqual(found.count, 1, "Cyrillic case-insensitive search")
    }
}

final class NormalizerTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(TextTools.normalize("  a \t b \r\n\n\n\n c  "), "a b\n\nc")
    }

    func testWords() {
        let w = TextTools.words(in: "Olá, mundo! 42 vezes.")
        XCTAssertEqual(w.map(\.text), ["Olá", "mundo", "vezes"])
    }
}

final class MarkedSentenceTests: XCTestCase {
    func testMarksExactOccurrence() {
        let t = "Primeira frase. Ela deixou o banco do jardim e foi ao banco levantar dinheiro. Fim."
        let ns = t as NSString
        let second = ns.range(of: "banco", options: [], range: NSRange(location: ns.range(of: "ao ").location, length: 20))
        let s = TextTools.markedSentence(in: t, start: second.location, end: second.location + second.length)
        XCTAssertEqual(s, "Ela deixou o banco do jardim e foi ao ⟦banco⟧ levantar dinheiro.")
    }
}
