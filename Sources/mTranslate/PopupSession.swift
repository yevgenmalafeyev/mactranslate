import Foundation
import mTranslateCore
import Observation

@MainActor @Observable
final class PopupSession {
    enum Route: Equatable {
        case snippet
        case card(CardJob)
        static func == (a: Route, b: Route) -> Bool {
            switch (a, b) {
            case (.snippet, .snippet): true
            case (.card(let x), .card(let y)): x === y
            default: false
            }
        }
    }

    let text: String
    let tokens: [WordToken]
    var snippet: SnippetContext?
    var source: Language?
    var sourceConfirmed = false
    var tabs: [TabTarget] = []
    var active: TabTarget?
    var jobs: [String: TabJob] = [:]
    var route: Route = .snippet
    /// Opened from history directly into a card: ESC closes instead of going back.
    var cardOnly = false
    /// The text came from an mtranslate:// link and waits for the user's click; until then nothing runs.
    var pendingLink = false

    private var settings: AppSettings { SettingsStore.shared.s }

    init(text: String) {
        let norm = TextTools.normalize(text)
        self.text = norm
        self.tokens = TextTools.words(in: norm)
    }

    var activeJob: TabJob? { active.flatMap { jobs[$0.id] } }

    /// The user accepted the text of a link.
    func confirmLink() {
        guard pendingLink else { return }
        pendingLink = false
        Task { await start() }
    }

    func start() async {
        guard !pendingLink else { return }
        let hash = TextTools.hash(text)
        let hints = Array(Set(settings.enabled.map(\.base)))
        if let r = try? await Store.shared.touchSnippet(hash: hash, text: text) {
            snippet = SnippetContext(id: r.id, text: text, hash: hash)
            if let s = r.sourceLang {
                source = LanguageRegistry.forCode(s)
                sourceConfirmed = true
            }
        } else {
            snippet = SnippetContext(id: -1, text: text, hash: hash)
        }
        if source == nil, let g = TextTools.guessLanguage(text, hints: hints), g.confidence >= 0.6 {
            source = LanguageRegistry.forCode(g.code)
        }
        tabs = TabPlan.tabs(enabled: settings.enabled, source: source)
        active = TabPlan.initial(tabs: tabs, defaultId: settings.defaultLanguage, secondId: settings.secondDefaultLanguage)
        if let active { ensureJob(active) }
        if settings.prefetchAll { tabs.forEach(ensureJob) }
    }

    func select(_ t: TabTarget) {
        guard !pendingLink else { return }
        active = t
        route = .snippet
        ensureJob(t)
    }

    func select(index: Int) {
        guard index >= 0, index < tabs.count else { return }
        select(tabs[index])
    }

    func ensureJob(_ t: TabTarget) {
        guard let snippet, jobs[t.id] == nil else { return }
        let j = JobCenter.shared.tabJob(snippet: snippet, target: t)
        jobs[t.id] = j
        attach(j)
    }

    func retry(_ t: TabTarget) {
        jobs[t.id] = nil
        ensureJob(t)
    }

    private func attach(_ j: TabJob) {
        j.onLanguage = { [weak self] code in self?.reconcile(code) }
        let target = j.target
        j.onSame = { [weak self] in self?.handleSame(target) }
        if let d = j.detectedLang { reconcile(d) }
        if j.status == .same { handleSame(target) }
    }

    /// Claude's detected language is authoritative.
    private func reconcile(_ code: String) {
        let lang = LanguageRegistry.forCode(code)
        if sourceConfirmed, source?.base == lang.base { return }
        sourceConfirmed = true
        let changed = source?.base != lang.base || !tabs.contains(where: \.isMono)
        source = lang
        guard changed else { return }
        let newTabs = TabPlan.tabs(enabled: settings.enabled, source: lang)
        tabs = newTabs
        jobs = jobs.filter { id, _ in newTabs.contains { $0.id == id } }
        if let a = active, !newTabs.contains(a) {
            active = TabPlan.initial(tabs: newTabs, defaultId: settings.defaultLanguage, secondId: settings.secondDefaultLanguage)
            if let active { ensureJob(active) }
        }
        if settings.prefetchAll { newTabs.forEach(ensureJob) }
    }

    private func handleSame(_ t: TabTarget) {
        tabs.removeAll { $0 == t }
        jobs[t.id] = nil
        if active == t {
            active = TabPlan.initial(tabs: tabs, defaultId: settings.defaultLanguage, secondId: settings.secondDefaultLanguage)
            if let active { ensureJob(active) }
        }
    }

    // MARK: Words

    /// Lowercased surface words that appear in the active tab's word list (for underlining).
    var listedWords: Set<String> {
        guard let j = activeJob else { return [] }
        var s = Set<String>()
        for w in j.words {
            for part in TextTools.words(in: w.w) { s.insert(part.text.lowercased()) }
        }
        return s
    }

    func entry(for token: WordToken) -> WordEntry? {
        let t = token.text.lowercased()
        return activeJob?.words.first { e in TextTools.words(in: e.w).contains { $0.text.lowercased() == t } }
    }

    func openCard(token: WordToken) {
        let e = entry(for: token)
        // Mark the phrase if the token belongs to a listed multi-word expression, else the token itself.
        var start = token.start, end = token.end
        if let e, e.w.lowercased() != token.text.lowercased() {
            let ns = text as NSString
            let r = ns.range(of: e.w, options: .caseInsensitive,
                             range: NSRange(location: max(0, token.start - e.w.utf16.count), length: min(ns.length - max(0, token.start - e.w.utf16.count), e.w.utf16.count * 2 + token.text.utf16.count)))
            if r.location != NSNotFound { start = r.location; end = r.location + r.length }
        }
        openCard(surface: e?.w ?? token.text, sentence: TextTools.markedSentence(in: text, start: start, end: end))
    }

    func openCard(entry: WordEntry) {
        let r = (text as NSString).range(of: entry.w, options: .caseInsensitive)
        let sentence = r.location == NSNotFound
            ? TextTools.sentence(in: text, around: 0)
            : TextTools.markedSentence(in: text, start: r.location, end: r.location + r.length)
        openCard(surface: entry.w, sentence: sentence)
    }

    private func openCard(surface: String, sentence: String) {
        guard !pendingLink, let target = active else { return }
        let j = JobCenter.shared.cardJob(surface: surface, sentence: sentence, source: source, target: target)
        route = .card(j)
    }

    func back() {
        route = .snippet
    }
}
