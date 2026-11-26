import Foundation

public struct SnippetRow: Identifiable, Hashable, Sendable {
    public let id: Int64
    public let text: String
    public let sourceLang: String?
    public let lastUsed: Date
}

public struct CardRow: Identifiable, Hashable, Sendable {
    public var id: String { [lemma, sourceLang, target].joined(separator: "|") }
    public let lemma: String
    public let sourceLang: String
    public let target: String
    public let lastUsed: Date
}

public struct CachedTranslation: Sendable {
    public let translation: String
    public let words: [WordEntry]
}

public actor Store {
    public static let shared = Store()

    private var db: SQLiteDB?

    public init() {}

    public static var directory: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("mTranslate", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: d.path)
        return d
    }

    /// For tests: open a store at an explicit path.
    public init(path: String) throws {
        let d = try SQLiteDB(path: path)
        try Self.migrate(d)
        db = d
    }

    private func conn() throws -> SQLiteDB {
        if let db { return db }
        let d = try SQLiteDB(path: Self.directory.appendingPathComponent("store.sqlite").path)
        try Self.migrate(d)
        db = d
        return d
    }

    private static func migrate(_ d: SQLiteDB) throws {
        if d.userVersion < 1 {
            try d.exec("""
            CREATE TABLE IF NOT EXISTS snippets(id INTEGER PRIMARY KEY, hash TEXT UNIQUE, text TEXT, text_folded TEXT,
                source_lang TEXT, created_at REAL, last_used_at REAL, use_count INTEGER DEFAULT 0);
            CREATE TABLE IF NOT EXISTS translations(snippet_id INTEGER REFERENCES snippets(id) ON DELETE CASCADE,
                target TEXT, level TEXT, prompt_v INTEGER, model TEXT, translation TEXT, words_json TEXT, created_at REAL,
                PRIMARY KEY(snippet_id, target, level, prompt_v));
            CREATE TABLE IF NOT EXISTS word_forms(surface TEXT, source_lang TEXT, lemma TEXT, PRIMARY KEY(surface, source_lang));
            CREATE TABLE IF NOT EXISTS word_cards(lemma TEXT, source_lang TEXT, target TEXT, prompt_v INTEGER, model TEXT,
                lemma_folded TEXT, card_json TEXT, created_at REAL, last_used_at REAL,
                PRIMARY KEY(lemma, source_lang, target, prompt_v));
            CREATE TABLE IF NOT EXISTS image_cache(query TEXT PRIMARY KEY, hits_json TEXT, fetched_at REAL);
            CREATE INDEX IF NOT EXISTS snippets_used ON snippets(last_used_at);
            CREATE INDEX IF NOT EXISTS cards_used ON word_cards(last_used_at);
            PRAGMA user_version = 1;
            """)
        }
        if d.userVersion < 2 {
            try d.exec("""
            CREATE TABLE IF NOT EXISTS word_context(lemma TEXT, source_lang TEXT, target TEXT, sentence_hash TEXT, sense INTEGER,
                PRIMARY KEY(lemma, source_lang, target, sentence_hash));
            PRAGMA user_version = 2;
            """)
        }
    }

    private var now: Double { Date().timeIntervalSince1970 }

    // MARK: Snippets

    /// Insert or touch a snippet; returns (id, known source language).
    public func touchSnippet(hash: String, text: String) throws -> (id: Int64, sourceLang: String?) {
        let d = try conn()
        try d.run("""
            INSERT INTO snippets(hash, text, text_folded, created_at, last_used_at, use_count) VALUES(?,?,?,?,?,1)
            ON CONFLICT(hash) DO UPDATE SET last_used_at=excluded.last_used_at, use_count=use_count+1
            """, [.text(hash), .text(text), .text(TextTools.fold(text)), .double(now), .double(now)])
        let r = try d.query("SELECT id, source_lang FROM snippets WHERE hash=?", [.text(hash)])
        guard let row = r.first, let id = row[0].int else { throw SQLError(description: "snippet missing") }
        return (id, row[1].string)
    }

    public func setSourceLang(snippetId: Int64, lang: String) throws {
        try conn().run("UPDATE snippets SET source_lang=? WHERE id=?", [.text(lang), .int(snippetId)])
    }

    public func translation(snippetId: Int64, target: String, level: String) throws -> CachedTranslation? {
        let r = try conn().query("SELECT translation, words_json FROM translations WHERE snippet_id=? AND target=? AND level=? AND prompt_v=?",
                                 [.int(snippetId), .text(target), .text(level), .int(Int64(Prompts.promptVersion))])
        guard let row = r.first, let t = row[0].string else { return nil }
        let words = row[1].string.flatMap { try? JSONDecoder().decode([WordEntry].self, from: Data($0.utf8)) } ?? []
        return CachedTranslation(translation: t, words: words)
    }

    public func saveTranslation(snippetId: Int64, target: String, level: String, model: String, translation: String, words: [WordEntry]) throws {
        let json = String(decoding: (try? JSONEncoder().encode(words)) ?? Data("[]".utf8), as: UTF8.self)
        try conn().run("INSERT OR REPLACE INTO translations VALUES(?,?,?,?,?,?,?,?)",
                       [.int(snippetId), .text(target), .text(level), .int(Int64(Prompts.promptVersion)), .text(model),
                        .text(translation), .text(json), .double(now)])
    }

    // MARK: Words

    public func saveForms(_ pairs: [(surface: String, lemma: String)], sourceLang: String, replace: Bool = true) throws {
        let d = try conn()
        for p in pairs {
            try d.run("INSERT OR \(replace ? "REPLACE" : "IGNORE") INTO word_forms VALUES(?,?,?)",
                      [.text(p.surface.lowercased()), .text(sourceLang), .text(p.lemma)])
        }
    }

    public func lemma(surface: String, sourceLang: String) throws -> String? {
        try conn().query("SELECT lemma FROM word_forms WHERE surface=? AND source_lang=?",
                         [.text(surface.lowercased()), .text(sourceLang)]).first?[0].string
    }

    public func card(lemma: String, sourceLang: String, target: String) throws -> WordCard? {
        let d = try conn()
        let args: [SQLValue] = [.text(lemma), .text(sourceLang), .text(target), .int(Int64(Prompts.promptVersion))]
        guard let json = try d.query("SELECT card_json FROM word_cards WHERE lemma=? AND source_lang=? AND target=? AND prompt_v=?", args).first?[0].string
        else { return nil }
        try d.run("UPDATE word_cards SET last_used_at=? WHERE lemma=? AND source_lang=? AND target=? AND prompt_v=?", [.double(now)] + args)
        return try? JSONDecoder().decode(WordCard.self, from: Data(json.utf8))
    }

    public func saveCard(_ card: WordCard, sourceLang: String, target: String, model: String) throws {
        let json = String(decoding: try JSONEncoder().encode(card), as: UTF8.self)
        // A card that exists is never overwritten: a later text can't swap a word's known card for its own.
        try conn().run("INSERT OR IGNORE INTO word_cards VALUES(?,?,?,?,?,?,?,?,?)",
                       [.text(card.head.lemma), .text(sourceLang), .text(target), .int(Int64(Prompts.promptVersion)), .text(model),
                        .text(TextTools.fold(card.head.lemma)), .text(json), .double(now), .double(now)])
    }

    /// Which sense (0-based) of a card is used in a given sentence.
    public func contextSense(lemma: String, sourceLang: String, target: String, sentence: String) throws -> Int? {
        try conn().query("SELECT sense FROM word_context WHERE lemma=? AND source_lang=? AND target=? AND sentence_hash=?",
                         [.text(lemma), .text(sourceLang), .text(target), .text(TextTools.hash(sentence))]).first?[0].int.map(Int.init)
    }

    public func saveContextSense(lemma: String, sourceLang: String, target: String, sentence: String, sense: Int) throws {
        try conn().run("INSERT OR REPLACE INTO word_context VALUES(?,?,?,?,?)",
                       [.text(lemma), .text(sourceLang), .text(target), .text(TextTools.hash(sentence)), .int(Int64(sense))])
    }

    // MARK: Images

    public func imageHits(query: String) throws -> [ImageHit]? {
        guard let row = try conn().query("SELECT hits_json, fetched_at FROM image_cache WHERE query=?", [.text(query)]).first,
              let json = row[0].string
        else { return nil }
        // Expire after a day: empty results shouldn't stick, and Pixabay image URLs are only valid ~24 h
        // (their terms also forbid permanent hotlinking / caching search results longer than 24 h).
        let hits = (try? JSONDecoder().decode([ImageHit].self, from: Data(json.utf8))) ?? []
        if let t = row[1].double, now - t > 86_400, hits.isEmpty || hits.contains(where: { $0.provider == "Pixabay" }) { return nil }
        return hits
    }

    public func saveImageHits(query: String, hits: [ImageHit]) throws {
        let json = String(decoding: try JSONEncoder().encode(hits), as: UTF8.self)
        try conn().run("INSERT OR REPLACE INTO image_cache VALUES(?,?,?)", [.text(query), .text(json), .double(now)])
    }

    // MARK: History

    public func recentSnippets(search: String, limit: Int = 300) throws -> [SnippetRow] {
        let s = search.trimmingCharacters(in: .whitespaces)
        let sql = s.isEmpty
            ? "SELECT id, text, source_lang, last_used_at FROM snippets ORDER BY last_used_at DESC LIMIT ?"
            : "SELECT id, text, source_lang, last_used_at FROM snippets WHERE text_folded LIKE ? ORDER BY last_used_at DESC LIMIT ?"
        let args: [SQLValue] = s.isEmpty ? [.int(Int64(limit))] : [.text("%" + TextTools.fold(s) + "%"), .int(Int64(limit))]
        return try conn().query(sql, args).compactMap { r in
            guard let id = r[0].int, let t = r[1].string else { return nil }
            return SnippetRow(id: id, text: t, sourceLang: r[2].string, lastUsed: Date(timeIntervalSince1970: r[3].double ?? 0))
        }
    }

    public func recentCards(search: String, limit: Int = 300) throws -> [CardRow] {
        let s = search.trimmingCharacters(in: .whitespaces)
        let base = "SELECT lemma, source_lang, target, MAX(last_used_at) FROM word_cards"
        let sql = s.isEmpty
            ? base + " GROUP BY lemma, source_lang, target ORDER BY 4 DESC LIMIT ?"
            : base + " WHERE lemma_folded LIKE ? GROUP BY lemma, source_lang, target ORDER BY 4 DESC LIMIT ?"
        let args: [SQLValue] = s.isEmpty ? [.int(Int64(limit))] : [.text("%" + TextTools.fold(s) + "%"), .int(Int64(limit))]
        return try conn().query(sql, args).compactMap { r in
            guard let l = r[0].string, let src = r[1].string, let t = r[2].string else { return nil }
            return CardRow(lemma: l, sourceLang: src, target: t, lastUsed: Date(timeIntervalSince1970: r[3].double ?? 0))
        }
    }

    public func snippetText(id: Int64) throws -> String? {
        try conn().query("SELECT text FROM snippets WHERE id=?", [.int(id)]).first?[0].string
    }

    public func deleteSnippet(id: Int64) throws {
        let d = try conn()
        try d.run("DELETE FROM translations WHERE snippet_id=?", [.int(id)])
        try d.run("DELETE FROM snippets WHERE id=?", [.int(id)])
        // Deleted text must not linger in the write-ahead log.
        try? d.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    public func deleteCard(lemma: String, sourceLang: String, target: String) throws {
        let d = try conn()
        try d.run("DELETE FROM word_cards WHERE lemma=? AND source_lang=? AND target=?",
                  [.text(lemma), .text(sourceLang), .text(target)])
        // With the card go the word forms that led to it and its remembered contexts.
        if try d.query("SELECT 1 FROM word_cards WHERE lemma=? AND source_lang=? LIMIT 1", [.text(lemma), .text(sourceLang)]).isEmpty {
            try d.run("DELETE FROM word_forms WHERE lemma=? AND source_lang=?", [.text(lemma), .text(sourceLang)])
        }
        try d.run("DELETE FROM word_context WHERE lemma=? AND source_lang=? AND target=?",
                  [.text(lemma), .text(sourceLang), .text(target)])
        try? d.exec("PRAGMA wal_checkpoint(TRUNCATE);")
    }
}
