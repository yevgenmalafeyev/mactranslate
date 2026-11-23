import Foundation

/// One entry of a tab's word list.
public struct WordEntry: Codable, Hashable, Sendable, Identifiable {
    public var w: String
    public var l: String
    public var p: String
    public var m: [String]
    public var ex: String?

    public var id: String { l.lowercased() + "|" + w.lowercased() }

    public init(w: String, l: String, p: String, m: [String], ex: String? = nil) {
        self.w = w; self.l = l; self.p = p; self.m = m; self.ex = ex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        w = try c.decode(String.self, forKey: .w)
        l = (try? c.decodeIfPresent(String.self, forKey: .l)) ?? w
        p = (try? c.decodeIfPresent(String.self, forKey: .p)) ?? ""
        m = (try? c.decodeIfPresent([String].self, forKey: .m)) ?? []
        ex = try? c.decodeIfPresent(String.self, forKey: .ex)
    }
}

public struct CardHeader: Codable, Hashable, Sendable {
    public var lemma: String
    public var pos: String
    public var gender: String?
    public var ipa: String?
    public var forms: String?
    public var note: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lemma = try c.decode(String.self, forKey: .lemma)
        pos = (try? c.decodeIfPresent(String.self, forKey: .pos)) ?? ""
        gender = (try? c.decodeIfPresent(String.self, forKey: .gender)) ?? nil
        ipa = (try? c.decodeIfPresent(String.self, forKey: .ipa)) ?? nil
        forms = (try? c.decodeIfPresent(String.self, forKey: .forms)) ?? nil
        note = (try? c.decodeIfPresent(String.self, forKey: .note)) ?? nil
    }
}

public struct CardExample: Codable, Hashable, Sendable {
    public var s: String
    public var t: String?
}

public struct CardSense: Codable, Hashable, Sendable, Identifiable {
    public var gloss: String
    public var tr: [String]
    public var def: String
    public var ex: [CardExample]
    public var img: String
    public var wiki: String?
    public var abstract: Bool
    /// True for the meaning used in the sentence the card was requested for.
    public var here: Bool?

    public var id: String { gloss + "|" + img }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gloss = (try? c.decodeIfPresent(String.self, forKey: .gloss)) ?? ""
        tr = (try? c.decodeIfPresent([String].self, forKey: .tr)) ?? []
        def = (try? c.decodeIfPresent(String.self, forKey: .def)) ?? ""
        ex = (try? c.decodeIfPresent([CardExample].self, forKey: .ex)) ?? []
        img = (try? c.decodeIfPresent(String.self, forKey: .img)) ?? gloss
        wiki = (try? c.decodeIfPresent(String.self, forKey: .wiki)) ?? nil
        abstract = (try? c.decodeIfPresent(Bool.self, forKey: .abstract)) ?? false
        here = (try? c.decodeIfPresent(Bool.self, forKey: .here)) ?? nil
    }
}

public struct WordCard: Codable, Hashable, Sendable {
    public var head: CardHeader
    public var senses: [CardSense]
    public init(head: CardHeader, senses: [CardSense]) { self.head = head; self.senses = senses }
}

public struct ImageHit: Codable, Hashable, Sendable, Identifiable {
    public var thumbURL: URL
    public var fullURL: URL
    public var provider: String
    public var credit: String
    public var pageURL: URL?
    public var id: URL { thumbURL }

    public init(thumbURL: URL, fullURL: URL, provider: String, credit: String, pageURL: URL?) {
        self.thumbURL = thumbURL; self.fullURL = fullURL; self.provider = provider; self.credit = credit; self.pageURL = pageURL
    }
}
