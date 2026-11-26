import Foundation

public struct Language: Hashable, Codable, Sendable, Identifiable {
    /// Stable identifier, e.g. "ru", "pt-PT".
    public let id: String
    /// ISO 639-1 base code used for source comparison, e.g. "pt".
    public let base: String
    public let englishName: String
    public let nativeName: String
    /// BCP-47 locale for AVSpeechSynthesisVoice.
    public let ttsLocale: String
    /// Extra instructions injected into prompts when this language is written.
    public let promptRules: String

    public init(id: String, base: String, englishName: String, nativeName: String, ttsLocale: String, promptRules: String = "") {
        self.id = id
        self.base = base
        self.englishName = englishName
        self.nativeName = nativeName
        self.ttsLocale = ttsLocale
        self.promptRules = promptRules
    }
}

public enum LanguageRegistry {
    public static let ptPTRules = """
    Write European Portuguese (pt-PT) only, as written in Portugal under the 1990 Orthographic Agreement. Never use Brazilian spelling, vocabulary or grammar. Examples: autocarro (not ônibus), comboio (not trem), telemóvel (not celular), pequeno-almoço (not café da manhã), casa de banho (not banheiro), ecrã (not tela), ficheiro (not arquivo), equipa (not time), utilizador (not usuário), facto (not fato), receção, económico, António. Use "estar a + infinitive" (estou a fazer), not the gerund (estou fazendo). Use enclitic pronouns (chamo-me, disse-me). Use tu / o senhor as in Portugal. If a source word is specifically Brazilian, say so and give the pt-PT equivalent.
    """

    public static let all: [Language] = [
        Language(id: "uk", base: "uk", englishName: "Ukrainian", nativeName: "Українська", ttsLocale: "uk-UA"),
        Language(id: "ru", base: "ru", englishName: "Russian", nativeName: "Русский", ttsLocale: "ru-RU"),
        Language(id: "pt-PT", base: "pt", englishName: "European Portuguese", nativeName: "Português (PT)", ttsLocale: "pt-PT", promptRules: ptPTRules),
        Language(id: "en", base: "en", englishName: "English", nativeName: "English", ttsLocale: "en-GB"),
        Language(id: "de", base: "de", englishName: "German", nativeName: "Deutsch", ttsLocale: "de-DE"),
        Language(id: "es", base: "es", englishName: "Spanish", nativeName: "Español", ttsLocale: "es-ES"),
        Language(id: "fr", base: "fr", englishName: "French", nativeName: "Français", ttsLocale: "fr-FR"),
        Language(id: "it", base: "it", englishName: "Italian", nativeName: "Italiano", ttsLocale: "it-IT"),
        Language(id: "pl", base: "pl", englishName: "Polish", nativeName: "Polski", ttsLocale: "pl-PL"),
        Language(id: "nl", base: "nl", englishName: "Dutch", nativeName: "Nederlands", ttsLocale: "nl-NL"),
        Language(id: "tr", base: "tr", englishName: "Turkish", nativeName: "Türkçe", ttsLocale: "tr-TR"),
        Language(id: "zh", base: "zh", englishName: "Chinese (Simplified)", nativeName: "中文", ttsLocale: "zh-CN"),
    ]

    public static func byId(_ id: String) -> Language? {
        all.first { $0.id == id }
    }

    /// Resolve an ISO code returned by Claude / NL ("pt", "pt-BR", "en") to a Language.
    /// Unknown codes produce an ad-hoc Language so a monolingual tab can still be shown.
    public static func forCode(_ raw: String) -> Language {
        let code = raw.lowercased().trimmingCharacters(in: .whitespaces)
        let base = String(code.split(separator: "-").first ?? Substring(code))
        if let l = all.first(where: { $0.id.lowercased() == code }) { return l }
        if let l = all.first(where: { $0.base == base }) { return l }
        let en = Locale(identifier: "en").localizedString(forLanguageCode: base) ?? base
        let native = Locale(identifier: base).localizedString(forLanguageCode: base)?.capitalized ?? en
        return Language(id: base, base: base, englishName: en, nativeName: native, ttsLocale: base)
    }
}
