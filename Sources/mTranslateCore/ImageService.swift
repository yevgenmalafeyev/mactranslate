import Foundation
import ImageIO

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

    /// Nothing from API calls is written to disk: request URLs carry the Pixabay key, and results are
    /// already cached in the store. Redirects are not followed (the endpoints are fixed and don't need them).
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.timeoutIntervalForRequest = 6
        c.timeoutIntervalForResource = 20
        c.httpAdditionalHeaders = ["User-Agent": "mTranslate/1.0 (https://github.com/yevgenmalafeyev/mtranslate)"]
        return URLSession(configuration: c, delegate: NoRedirects(), delegateQueue: nil)
    }()

    /// Largest API answer accepted (real ones are a few kB).
    static let maxBody = 2 << 20

    /// Hosts thumbnails may be loaded from, per provider. Anything else an API (or a tampered cache) names
    /// is dropped, so showing a card can't make the app contact an arbitrary server.
    static let imageHosts: [String: [String]] = [
        "Pixabay": ["pixabay.com"],
        "Pexels": ["pexels.com"],
        "Wikipedia": ["wikimedia.org"],
        "Wikimedia": ["wikimedia.org"],
        "Openverse": ["openverse.org"],
    ]

    static func isHTTPS(_ u: URL, hosts: [String]? = nil) -> Bool {
        guard u.scheme?.lowercased() == "https",
              let host = URLComponents(url: u, resolvingAgainstBaseURL: false)?.percentEncodedHost?.lowercased(),
              host.range(of: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$", options: .regularExpression) != nil,
              u.user == nil, u.password == nil, u.port == nil
        else { return false }
        guard let hosts else { return true }
        return hosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// A search query made of model output, reduced to a few plain words; nil if nothing usable is left.
    public static func cleanQuery(_ s: String, maxLength: Int = 60, maxWords: Int = 6) -> String? {
        let plain = s.replacingOccurrences(of: "[^\\p{L}\\p{N}'(),. -]+", with: " ", options: .regularExpression)
        let words = plain.split(separator: " ").prefix(maxWords)
        let q = String(words.joined(separator: " ").prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? nil : q
    }

    /// Largest thumbnail accepted, and the size it is decoded to.
    static let maxImageBytes = 4 << 20
    static let maxImagePixels = 1200

    private let thumbs: NSCache<NSURL, CGImage> = {
        let c = NSCache<NSURL, CGImage>()
        c.countLimit = 60
        return c
    }()

    /// Loads a thumbnail the careful way: provider host only, no redirects, nothing written to disk,
    /// size-capped, must be an image, decoded to a bounded bitmap.
    public func thumbnail(_ hit: ImageHit) async -> CGImage? {
        let url = hit.thumbURL
        guard let hosts = Self.imageHosts[hit.provider], Self.isHTTPS(url, hosts: hosts) else { return nil }
        if let c = thumbs.object(forKey: url as NSURL) { return c }
        guard let (bytes, resp) = try? await session.bytes(for: URLRequest(url: url)),
              let http = resp as? HTTPURLResponse, http.statusCode == 200,
              (http.mimeType ?? "").lowercased().hasPrefix("image/"), (http.mimeType ?? "").lowercased() != "image/svg+xml",
              resp.expectedContentLength <= Int64(Self.maxImageBytes)
        else { return nil }
        var data = Data()
        if resp.expectedContentLength > 0 { data.reserveCapacity(Int(resp.expectedContentLength)) }
        do {
            for try await b in bytes {
                data.append(b)
                if data.count > Self.maxImageBytes { return nil }
            }
        } catch { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: Self.maxImagePixels]
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        else { return nil }
        thumbs.setObject(img, forKey: url as NSURL)
        return img
    }

    /// Keeps only hits whose thumbnail is on the provider's own host; other links must at least be https.
    static func vetted(_ hits: [ImageHit]) -> [ImageHit] {
        hits.compactMap { h in
            guard let hosts = imageHosts[h.provider], isHTTPS(h.thumbURL, hosts: hosts) else { return nil }
            var h = h
            if !isHTTPS(h.fullURL) { h.fullURL = h.thumbURL }
            if let p = h.pageURL, !isHTTPS(p) { h.pageURL = nil }
            return h
        }
    }

    private var inflight: [String: Task<[ImageHit], Never>] = [:]

    public init() {}

    public func hits(query: String, wiki: String?, providers: ImageProviders) async -> [ImageHit] {
        let key = query.lowercased() + "|" + (wiki ?? "")
        if let cached = try? await Store.shared.imageHits(query: key) { return Self.vetted(cached) }
        if let t = inflight[key] { return await t.value }
        let t = Task { Self.vetted(await self.fetch(query: query, wiki: wiki, providers: providers)) }
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
            guard data.count <= Self.maxBody else { return .unreachable("Unexpected answer from the provider") }
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
        guard let (bytes, resp) = try? await session.bytes(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200, resp.expectedContentLength <= Int64(Self.maxBody)
        else { return nil }
        var data = Data()
        do {
            for try await b in bytes {
                data.append(b)
                if data.count > Self.maxBody { return nil }
            }
        } catch { return nil }
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

private final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
