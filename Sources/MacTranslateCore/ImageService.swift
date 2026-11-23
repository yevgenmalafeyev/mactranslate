import Foundation

public struct ImageProviders: Sendable {
    public var pixabayKey: String?
    public var pixabay: Bool
    public var pexelsKey: String?
    public var pexels: Bool
    public var wikimedia: Bool
    public var openverse: Bool
    public init(pixabayKey: String?, pixabay: Bool, pexelsKey: String?, pexels: Bool, wikimedia: Bool, openverse: Bool) {
        self.pixabayKey = pixabayKey; self.pixabay = pixabay
        self.pexelsKey = pexelsKey; self.pexels = pexels; self.wikimedia = wikimedia; self.openverse = openverse
    }
}

public enum KeyedImageProvider: Sendable { case pixabay, pexels }

public enum KeyCheck: Sendable, Equatable {
    case ok
    case rejected(String)
    case unreachable(String)
}

public actor ImageService {
    public static let shared = ImageService()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.urlCache = URLCache(memoryCapacity: 4 << 20, diskCapacity: 64 << 20)
        c.timeoutIntervalForRequest = 6
        c.httpAdditionalHeaders = ["User-Agent": "MacTranslate/1.0 (https://github.com/yevgenmalafeyev/mactranslate)"]
        return URLSession(configuration: c)
    }()

    private var inflight: [String: Task<[ImageHit], Never>] = [:]

    public init() {}

    public func hits(query: String, wiki: String?, providers: ImageProviders) async -> [ImageHit] {
        let key = query.lowercased() + "|" + (wiki ?? "")
        if let cached = try? await Store.shared.imageHits(query: key) { return cached }
        if let t = inflight[key] { return await t.value }
        let t = Task { await self.fetch(query: query, wiki: wiki, providers: providers) }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        try? await Store.shared.saveImageHits(query: key, hits: r)
        return r
    }

    private func fetch(query: String, wiki: String?, providers: ImageProviders) async -> [ImageHit] {
        if providers.pixabay, let k = providers.pixabayKey, !k.isEmpty {
            let r = await pixabay(query, key: k)
            if !r.isEmpty { return r }
        }
        if providers.pexels, let k = providers.pexelsKey, !k.isEmpty {
            let r = await pexels(query, key: k)
            if !r.isEmpty { return r }
        }
        if providers.wikimedia {
            if let w = wiki, !w.isEmpty {
                let r = await wikipedia(w)
                if !r.isEmpty { return r }
            }
            let r = await commons(query)
            if !r.isEmpty { return r }
        }
        if providers.openverse {
            return await openverse(query)
        }
        return []
    }

    /// Verify an API key with a tiny real search request.
    public func validate(_ provider: KeyedImageProvider, key: String) async -> KeyCheck {
        var req: URLRequest
        switch provider {
        case .pixabay:
            guard let u = url("https://pixabay.com/api/", ["key": key, "q": "cat", "per_page": "3"]) else { return .rejected("Bad key format") }
            req = URLRequest(url: u)
        case .pexels:
            guard let u = url("https://api.pexels.com/v1/search", ["query": "cat", "per_page": "1"]) else { return .rejected("Bad key format") }
            req = URLRequest(url: u)
            req.setValue(key, forHTTPHeaderField: "Authorization")
        }
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, (try? JSONSerialization.jsonObject(with: data)) is [String: Any] { return .ok }
            if code == 429 { return .unreachable("Rate limited by the provider — try again in a minute") }
            let body = String(decoding: data.prefix(200), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return .rejected("Key rejected (HTTP \(code))" + (body.isEmpty ? "" : ": \(body)"))
        } catch {
            return .unreachable("Could not reach the provider: \(error.localizedDescription)")
        }
    }

    private func json(_ req: URLRequest) async -> [String: Any]? {
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func url(_ base: String, _ items: [String: String]) -> URL? {
        var c = URLComponents(string: base)
        c?.queryItems = items.map { URLQueryItem(name: $0.key, value: $0.value) }
        return c?.url
    }

    private func pixabay(_ q: String, key: String) async -> [ImageHit] {
        guard let u = url("https://pixabay.com/api/", ["key": key, "q": String(q.prefix(100)), "image_type": "photo",
                                                       "per_page": "3", "safesearch": "true"]),
              let j = await json(URLRequest(url: u)), let hits = j["hits"] as? [[String: Any]]
        else { return [] }
        return hits.compactMap { h in
            guard let thumb = (h["webformatURL"] as? String).flatMap(URL.init(string:)) else { return nil }
            let full = (h["largeImageURL"] as? String).flatMap(URL.init(string:)) ?? thumb
            let who = h["user"] as? String ?? "Unknown"
            return ImageHit(thumbURL: thumb, fullURL: full, provider: "Pixabay", credit: "Image: \(who) / Pixabay",
                            pageURL: (h["pageURL"] as? String).flatMap(URL.init(string:)))
        }
    }

    private func pexels(_ q: String, key: String) async -> [ImageHit] {
        guard let u = url("https://api.pexels.com/v1/search", ["query": q, "per_page": "4", "orientation": "landscape"]) else { return [] }
        var req = URLRequest(url: u)
        req.setValue(key, forHTTPHeaderField: "Authorization")
        guard let j = await json(req), let photos = j["photos"] as? [[String: Any]] else { return [] }
        return photos.compactMap { p in
            guard let src = p["src"] as? [String: Any],
                  let thumb = (src["medium"] as? String).flatMap(URL.init(string:)),
                  let full = (src["large"] as? String).flatMap(URL.init(string:))
            else { return nil }
            let who = p["photographer"] as? String ?? "Unknown"
            return ImageHit(thumbURL: thumb, fullURL: full, provider: "Pexels", credit: "Photo: \(who) / Pexels",
                            pageURL: (p["url"] as? String).flatMap(URL.init(string:)))
        }
    }

    private func wikipedia(_ title: String) async -> [ImageHit] {
        let t = title.replacingOccurrences(of: " ", with: "_")
        guard let enc = t.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))),
              let u = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(enc)"),
              let j = await json(URLRequest(url: u)),
              let thumb = (j["thumbnail"] as? [String: Any])?["source"] as? String,
              let tu = URL(string: thumb)
        else { return [] }
        let full = ((j["originalimage"] as? [String: Any])?["source"] as? String).flatMap(URL.init(string:)) ?? tu
        let page = ((j["content_urls"] as? [String: Any])?["desktop"] as? [String: Any])?["page"] as? String
        return [ImageHit(thumbURL: tu, fullURL: full, provider: "Wikipedia", credit: "Wikipedia: \(j["title"] as? String ?? title)",
                         pageURL: page.flatMap(URL.init(string:)))]
    }

    private func commons(_ q: String) async -> [ImageHit] {
        guard let u = url("https://commons.wikimedia.org/w/api.php", [
            "action": "query", "format": "json", "generator": "search", "gsrnamespace": "6", "gsrlimit": "4",
            "gsrsearch": q + " filetype:bitmap", "prop": "imageinfo", "iiprop": "url|extmetadata", "iiurlwidth": "480",
        ]), let j = await json(URLRequest(url: u)),
              let pages = (j["query"] as? [String: Any])?["pages"] as? [String: Any]
        else { return [] }
        let sorted = pages.values.compactMap { $0 as? [String: Any] }.sorted { ($0["index"] as? Int ?? 0) < ($1["index"] as? Int ?? 0) }
        return sorted.compactMap { p in
            guard let info = (p["imageinfo"] as? [[String: Any]])?.first,
                  let thumb = (info["thumburl"] as? String).flatMap(URL.init(string:)),
                  let full = (info["url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            let meta = info["extmetadata"] as? [String: Any]
            let artist = ((meta?["Artist"] as? [String: Any])?["value"] as? String).map(Self.stripHTML) ?? "Wikimedia Commons"
            let lic = ((meta?["LicenseShortName"] as? [String: Any])?["value"] as? String) ?? ""
            return ImageHit(thumbURL: thumb, fullURL: full, provider: "Wikimedia",
                            credit: "\(artist)\(lic.isEmpty ? "" : ", " + lic) / Wikimedia Commons",
                            pageURL: (info["descriptionurl"] as? String).flatMap(URL.init(string:)))
        }
    }

    private func openverse(_ q: String) async -> [ImageHit] {
        guard let u = url("https://api.openverse.org/v1/images/", ["q": q, "page_size": "4"]),
              let j = await json(URLRequest(url: u)),
              let results = j["results"] as? [[String: Any]]
        else { return [] }
        return results.compactMap { r in
            guard let thumb = (r["thumbnail"] as? String).flatMap(URL.init(string:)),
                  let full = (r["url"] as? String).flatMap(URL.init(string:))
            else { return nil }
            let who = r["creator"] as? String ?? "Unknown"
            let lic = (r["license"] as? String ?? "").uppercased()
            return ImageHit(thumbURL: thumb, fullURL: full, provider: "Openverse", credit: "\(who), CC \(lic) / Openverse",
                            pageURL: (r["foreign_landing_url"] as? String).flatMap(URL.init(string:)))
        }
    }

    static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
