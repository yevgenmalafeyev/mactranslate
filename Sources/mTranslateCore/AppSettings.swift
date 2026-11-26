import Foundation

public enum ClaudeModel: String, Codable, CaseIterable, Sendable, Identifiable {
    case haiku, sonnet, opus
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public enum CEFRLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case A2, B1, B2, C1
    public var id: String { rawValue }
}

public enum TriggerMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case eventTap, clipboard
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .eventTap: "Keyboard tap (needs Input Monitoring)"
        case .clipboard: "Clipboard watch (no permission)"
        }
    }
}

public enum PopupPosition: String, Codable, CaseIterable, Sendable, Identifiable {
    case center, nearCursor
    public var id: String { rawValue }
    public var title: String { self == .center ? "Screen center" : "Near mouse cursor" }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var defaultLanguage = "uk"
    public var secondDefaultLanguage = "ru"
    public var enabledLanguages = ["uk", "ru", "pt-PT", "en", "de"]
    public var model: ClaudeModel = .sonnet
    public var level: CEFRLevel = .B2
    public var triggerMode: TriggerMode = .eventTap
    public var doublePressMs = 400
    public var popupPosition: PopupPosition = .center
    public var prefetchAll = false
    public var streaming = true
    public var launchAtLogin = true
    public var pixabayEnabled = true
    public var pexelsEnabled = true
    public var keepWarmMinutes = 10
    public var wikimediaEnabled = true
    public var openverseEnabled = true
    public var didInitialLoginRegistration = false

    public init() {}

    // Tolerant decoding: missing keys fall back to defaults so new settings never wipe old ones.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) -> T { (try? c.decodeIfPresent(T.self, forKey: k)) ?? def }
        defaultLanguage = v(.defaultLanguage, d.defaultLanguage)
        secondDefaultLanguage = v(.secondDefaultLanguage, d.secondDefaultLanguage)
        enabledLanguages = v(.enabledLanguages, d.enabledLanguages)
        model = v(.model, d.model)
        level = v(.level, d.level)
        triggerMode = v(.triggerMode, d.triggerMode)
        // Stored settings can be rewritten by any program, so values are kept inside the ranges the UI offers:
        // a huge double-press window would turn every second ⌘C into a translation request.
        doublePressMs = min(max(v(.doublePressMs, d.doublePressMs), 200), 1000)
        popupPosition = v(.popupPosition, d.popupPosition)
        prefetchAll = v(.prefetchAll, d.prefetchAll)
        streaming = v(.streaming, d.streaming)
        launchAtLogin = v(.launchAtLogin, d.launchAtLogin)
        pixabayEnabled = v(.pixabayEnabled, d.pixabayEnabled)
        pexelsEnabled = v(.pexelsEnabled, d.pexelsEnabled)
        keepWarmMinutes = min(max(v(.keepWarmMinutes, d.keepWarmMinutes), 0), 60)
        wikimediaEnabled = v(.wikimediaEnabled, d.wikimediaEnabled)
        openverseEnabled = v(.openverseEnabled, d.openverseEnabled)
        didInitialLoginRegistration = v(.didInitialLoginRegistration, d.didInitialLoginRegistration)
    }

    public var enabled: [Language] { enabledLanguages.compactMap(LanguageRegistry.byId) }
}

/// What a popup tab shows.
public enum TabTarget: Hashable, Sendable, Identifiable {
    case translate(Language)
    case mono(Language)

    public var id: String {
        switch self {
        case .translate(let l): l.id
        case .mono(let l): "mono:" + l.id
        }
    }
    /// Language the tab's content is written in.
    public var language: Language {
        switch self {
        case .translate(let l), .mono(let l): l
        }
    }
    public var isMono: Bool { if case .mono = self { true } else { false } }
}

public enum TabPlan {
    /// Translation tabs for every enabled language except the source, then a monolingual source tab.
    public static func tabs(enabled: [Language], source: Language?) -> [TabTarget] {
        guard let source else { return enabled.map { .translate($0) } }
        return enabled.filter { $0.base != source.base }.map { .translate($0) } + [.mono(source)]
    }

    public static func initial(tabs: [TabTarget], defaultId: String, secondId: String) -> TabTarget? {
        let ids = tabs.map(\.id)
        if ids.contains(defaultId) { return tabs.first { $0.id == defaultId } }
        if ids.contains(secondId) { return tabs.first { $0.id == secondId } }
        return tabs.first
    }
}
