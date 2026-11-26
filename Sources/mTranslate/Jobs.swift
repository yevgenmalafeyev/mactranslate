import Foundation
import mTranslateCore
import Observation
import os

let log = Logger(subsystem: "local.mtranslate.app", category: "app")

struct SnippetContext: Sendable {
    let id: Int64      // -1 when the store is unavailable (no caching)
    let text: String
    let hash: String
}

/// Limits concurrent claude processes.
actor Limiter {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { available = n }
    func acquire() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}

// MARK: - Tab job

@MainActor @Observable
final class TabJob {
    enum Status: Equatable {
        case loading, streaming, done, same
        case failed(ClaudeError)
    }

    let key: String
    let target: TabTarget
    var status: Status = .loading
    var translation = ""
    var words: [WordEntry] = []
    var fromCache = false
    var elapsed: Double?
    var rateNote: String?
    var detectedLang: String?
    var model: ClaudeModel

    @ObservationIgnored var onLanguage: ((String) -> Void)?
    @ObservationIgnored var onSame: (() -> Void)?
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var timedOut = false

    init(key: String, target: TabTarget, model: ClaudeModel) {
        self.key = key
        self.target = target
        self.model = model
    }

    var isFinished: Bool {
        switch status {
        case .done, .same, .failed: true
        default: false
        }
    }
}

// MARK: - Card job

@MainActor @Observable
final class CardJob: Identifiable {
    enum Status: Equatable {
        case loading, streaming, done
        case failed(ClaudeError)
    }

    let id = UUID()
    let surface: String
    let sentence: String
    let source: Language?
    let target: TabTarget
    var status: Status = .loading
    var head: CardHeader?
    var senses: [CardSense] = []
    var fromCache = false
    var images: [Int: [ImageHit]] = [:]
    var imagesLoading: Set<Int> = []
    var selectedSense = 0
    /// Index of the meaning used in the snippet sentence.
    var contextSense: Int?
    var resolvingContext = false
    /// Opened from History (no sentence context).
    var historyOnly = false
    @ObservationIgnored var userSelected = false
    @ObservationIgnored var task: Task<Void, Never>?
    @ObservationIgnored var timedOut = false

    func markContext(_ i: Int) {
        contextSense = i
        if !userSelected { selectedSense = i }
    }

    init(surface: String, sentence: String, source: Language?, target: TabTarget) {
        self.surface = surface
        self.sentence = sentence
        self.source = source
        self.target = target
    }

    var sourceKey: String { source?.id ?? "und" }
}

// MARK: - Job center

/// Owns running jobs so they survive the popup closing (finish & save to history).
@MainActor
final class JobCenter {
    static let shared = JobCenter()

    private var tabJobs: [String: TabJob] = [:]
    private var cardJobs: [String: CardJob] = [:]
    private let limiter = Limiter(3)
    private var binary: URL?
    private var settings: AppSettings { SettingsStore.shared.s }

    func cancelAll() {
        tabJobs.values.forEach { $0.task?.cancel() }
        cardJobs.values.forEach { $0.task?.cancel() }
        Task { await ClaudePool.shared.closeAll() }
    }

    func resetBinary() { binary = nil }

    private func claudeBinary() async -> URL? {
        if let binary, FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        let configured = settings.claudePath
        let found = await Task.detached { ClaudeLocator.locate(configured: configured) }.value
        binary = found
        return found
    }

    // MARK: Tabs

    func tabJob(snippet: SnippetContext, target: TabTarget) -> TabJob {
        let level = settings.level.rawValue
        let key = "\(snippet.hash)|\(target.id)|\(level)"
        if let j = tabJobs[key] { return j }
        let j = TabJob(key: key, target: target, model: settings.model)
        tabJobs[key] = j
        let lvl = settings.level
        j.task = Task { [weak self] in
            await self?.run(j, snippet: snippet, level: lvl)
            if self?.tabJobs[key] === j { self?.tabJobs[key] = nil }
        }
        return j
    }

    private func run(_ j: TabJob, snippet: SnippetContext, level: CEFRLevel) async {
        let started = Date()
        if snippet.id >= 0, let c = try? await Store.shared.translation(snippetId: snippet.id, target: j.target.id, level: level.rawValue) {
            j.translation = c.translation
            j.words = c.words
            j.fromCache = true
            j.status = .done
            return
        }
        guard let bin = await claudeBinary() else { j.status = .failed(.cliNotFound); return }

        let system = switch j.target {
        case .translate(let l): Prompts.translationSystem(target: l, level: level)
        case .mono(let l): Prompts.monoSystem(source: l, level: level)
        }
        let model = j.model
        let user = Prompts.snippetUser(snippet.text)
        let streaming = settings.streaming

        await limiter.acquire()
        let watchdog = Task { [weak j] in
            try? await Task.sleep(for: .seconds(20))
            if let j, j.status == .loading { j.timedOut = true; j.task?.cancel() }
            try? await Task.sleep(for: .seconds(40))
            if let j, !j.isFinished { j.timedOut = true; j.task?.cancel() }
        }

        var parser = SnippetStreamParser()
        var raw = ""
        var full: String?

        func apply(_ events: [SnippetStreamParser.Event]) {
            for e in events {
                switch e {
                case .language(let code):
                    guard j.detectedLang == nil else { break }
                    j.detectedLang = code
                    if snippet.id >= 0 { Task { try? await Store.shared.setSourceLang(snippetId: snippet.id, lang: code) } }
                    j.onLanguage?(code)
                case .translationDelta(let d):
                    if j.status == .loading { j.status = .streaming }
                    if streaming { j.translation += d }
                case .word(let w):
                    if streaming { j.words.append(w) }
                case .sameLanguage:
                    break
                }
            }
        }

        do {
            for try await ev in await ClaudePool.shared.stream(binary: bin, model: model, system: system, user: user) {
                switch ev {
                case .text(let t):
                    raw += t
                    apply(parser.feed(t))
                case .full(let f):
                    full = f
                case .rateLimit(let status, let resets, let util):
                    if status.hasPrefix("allowed") {
                        if let u = util, u >= 0.75 { j.rateNote = "\(Int(u * 100))% of usage limit" }
                    } else {
                        throw ClaudeError.rateLimited(resetsAt: resets)
                    }
                case .result(let isError, let msg):
                    if isError { throw ClaudeError.classify(status: 1, text: msg ?? "") }
                }
            }
            apply(parser.finish())
            if let full, full.trimmingCharacters(in: .whitespacesAndNewlines) != raw.trimmingCharacters(in: .whitespacesAndNewlines) {
                parser = SnippetStreamParser.parse(full)
                if j.detectedLang == nil, let l = parser.language { j.detectedLang = l; j.onLanguage?(l) }
            }
            if parser.isSame {
                j.status = .same
                j.onSame?()
            } else {
                guard !parser.cleanTranslation.isEmpty else { throw ClaudeError.malformedOutput }
                j.translation = parser.cleanTranslation
                j.words = parser.words
                j.elapsed = Date().timeIntervalSince(started)
                j.status = .done
                if snippet.id >= 0 {
                    let src = parser.language.map { LanguageRegistry.forCode($0).id } ?? (j.target.isMono ? j.target.language.id : nil)
                    let words = parser.words
                    let translation = parser.cleanTranslation
                    let target = j.target.id
                    let model = j.model.rawValue
                    Task.detached {
                        try? await Store.shared.saveTranslation(snippetId: snippet.id, target: target, level: level.rawValue,
                                                                model: model, translation: translation, words: words)
                        if let src {
                            try? await Store.shared.saveForms(words.map { ($0.w, $0.l) }, sourceLang: src)
                        }
                    }
                }
            }
        } catch {
            let ce: ClaudeError = j.timedOut ? .timeout : (error as? ClaudeError) ?? .failed(status: -1, detail: error.localizedDescription)
            log.error("tab job failed: \(String(describing: ce))")
            j.status = .failed(ce)
        }
        watchdog.cancel()
        await limiter.release()
    }

    // MARK: Cards

    func cardJob(surface: String, sentence: String, source: Language?, target: TabTarget) -> CardJob {
        let key = "\(surface.lowercased())|\(source?.id ?? "und")|\(target.id)"
        if let j = cardJobs[key], j.status != .failed(.timeout) { return j }
        let j = CardJob(surface: surface, sentence: sentence, source: source, target: target)
        cardJobs[key] = j
        j.task = Task { [weak self] in
            await self?.run(j)
            if self?.cardJobs[key] === j { self?.cardJobs[key] = nil }
        }
        return j
    }

    /// Open a cached card directly (history).
    func cachedCard(lemma: String, sourceLang: String, target: TabTarget) -> CardJob {
        let src = LanguageRegistry.forCode(sourceLang)
        let j = CardJob(surface: lemma, sentence: lemma, source: src, target: target)
        j.historyOnly = true
        j.task = Task { [weak self] in await self?.run(j) }
        return j
    }

    private func fill(_ j: CardJob, _ card: WordCard) {
        j.head = card.head
        j.senses = card.senses
        j.fromCache = true
        j.status = .done
        for i in card.senses.indices { loadImages(j, i) }
        Task { await resolveContext(j, card) }
    }

    /// For a cached card met in a (possibly) new sentence: find which meaning is used there.
    private func resolveContext(_ j: CardJob, _ card: WordCard) async {
        let src = j.sourceKey, target = j.target.id, lemma = card.head.lemma
        if j.historyOnly {
            if let i = card.senses.firstIndex(where: { $0.here == true }) { j.markContext(i) }
            return
        }
        if let i = try? await Store.shared.contextSense(lemma: lemma, sourceLang: src, target: target, sentence: j.sentence),
           i < card.senses.count {
            j.markContext(i); return
        }
        guard card.senses.count > 1, let bin = await claudeBinary() else {
            if card.senses.count == 1 { j.markContext(0) }
            return
        }
        j.resolvingContext = true
        defer { j.resolvingContext = false }
        var text = ""
        do {
            for try await ev in await ClaudePool.shared.stream(binary: bin, model: settings.model, system: Prompts.pickSenseSystem,
                                                              user: Prompts.pickSenseUser(word: j.surface, sentence: j.sentence, senses: card.senses)) {
                if case .text(let t) = ev { text += t }
            }
        } catch { return }
        if let n = Int(text.filter(\.isNumber).prefix(2)), n >= 1, n <= card.senses.count {
            j.markContext(n - 1)
            try? await Store.shared.saveContextSense(lemma: lemma, sourceLang: src, target: target, sentence: j.sentence, sense: n - 1)
        }
    }

    private func run(_ j: CardJob) async {
        let store = Store.shared
        let src = j.sourceKey
        let lemma = (try? await store.lemma(surface: j.surface, sourceLang: src)) ?? j.surface
        if let card = try? await store.card(lemma: lemma, sourceLang: src, target: j.target.id) {
            fill(j, card); return
        }
        guard let bin = await claudeBinary() else { j.status = .failed(.cliNotFound); return }
        let model = settings.model
        let system = Prompts.cardSystem(source: j.source, target: j.target)
        let user = Prompts.cardUser(word: j.surface, sentence: j.sentence)
        await limiter.acquire()
        let watchdog = Task { [weak j] in
            try? await Task.sleep(for: .seconds(20))
            if let j, j.status == .loading { j.timedOut = true; j.task?.cancel() }
            try? await Task.sleep(for: .seconds(45))
            if let j, j.status == .streaming { j.timedOut = true; j.task?.cancel() }
        }
        var parser = CardStreamParser()
        var full: String?
        var usedCache = false
        do {
            loop: for try await ev in await ClaudePool.shared.stream(binary: bin, model: model, system: system, user: user) {
                switch ev {
                case .text(let t):
                    for e in parser.feed(t) {
                        switch e {
                        case .head(let h):
                            if h.lemma.lowercased() != lemma.lowercased(),
                               let card = try? await store.card(lemma: h.lemma, sourceLang: src, target: j.target.id) {
                                fill(j, card)
                                usedCache = true
                                break loop
                            }
                            j.head = h
                            j.status = .streaming
                        case .sense(let s):
                            j.senses.append(s)
                            if s.here == true, j.contextSense == nil { j.markContext(j.senses.count - 1) }
                            loadImages(j, j.senses.count - 1)
                        }
                    }
                case .full(let f): full = f
                case .rateLimit(let status, let resets, _):
                    if !status.hasPrefix("allowed") { throw ClaudeError.rateLimited(resetsAt: resets) }
                case .result(let isError, let msg):
                    if isError { throw ClaudeError.classify(status: 1, text: msg ?? "") }
                }
            }
            if usedCache {
                try? await store.saveForms([(j.surface, j.head?.lemma ?? lemma)], sourceLang: src)
            } else {
                for e in parser.finish() {
                    if case .sense(let s) = e { j.senses.append(s); loadImages(j, j.senses.count - 1) }
                    if case .head(let h) = e { j.head = h }
                }
                if parser.card == nil || parser.senses.isEmpty, let full {
                    let p = CardStreamParser.parse(full)
                    if p.card != nil { parser = p; j.head = p.head; j.senses = p.senses
                        for i in p.senses.indices { loadImages(j, i) } }
                }
                guard let card = parser.card, !card.senses.isEmpty else { throw ClaudeError.malformedOutput }
                if j.contextSense == nil, let i = card.senses.firstIndex(where: { $0.here == true }) { j.markContext(i) }
                j.status = .done
                let ctx = j.contextSense
                let sentence = j.sentence
                let model = settings.model.rawValue
                let target = j.target.id
                let surface = j.surface
                Task.detached {
                    try? await store.saveCard(card, sourceLang: src, target: target, model: model)
                    try? await store.saveForms([(surface, card.head.lemma)], sourceLang: src)
                    if let ctx {
                        try? await store.saveContextSense(lemma: card.head.lemma, sourceLang: src, target: target,
                                                          sentence: sentence, sense: ctx)
                    }
                }
            }
        } catch {
            let ce: ClaudeError = j.timedOut ? .timeout : (error as? ClaudeError) ?? .failed(status: -1, detail: error.localizedDescription)
            log.error("card job failed: \(String(describing: ce))")
            j.status = .failed(ce)
        }
        watchdog.cancel()
        await limiter.release()
    }

    func loadImages(_ j: CardJob, _ i: Int) {
        guard i < j.senses.count, j.images[i] == nil, !j.imagesLoading.contains(i) else { return }
        let s = j.senses[i]
        j.imagesLoading.insert(i)
        let providers = SettingsStore.shared.imageProviders
        Task { [weak j] in
            let hits = await ImageService.shared.hits(query: s.img, wiki: s.wiki, providers: providers)
            j?.images[i] = hits
            j?.imagesLoading.remove(i)
        }
    }
}
