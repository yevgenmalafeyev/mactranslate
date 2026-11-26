import AVFoundation

@MainActor
final class Speech {
    static let shared = Speech()
    private var synth: AVSpeechSynthesizer?
    private var voiceCache: [String: AVSpeechSynthesisVoice?] = [:]

    func voice(for locale: String) -> AVSpeechSynthesisVoice? {
        if let v = voiceCache[locale] { return v }
        let norm = locale.replacingOccurrences(of: "_", with: "-").lowercased()
        let all = AVSpeechSynthesisVoice.speechVoices()
        var candidates = all.filter { $0.language.lowercased() == norm }
        if candidates.isEmpty, !norm.contains("-") {
            candidates = all.filter { $0.language.lowercased().hasPrefix(norm + "-") }
        }
        let v = candidates.max { $0.quality.rawValue < $1.quality.rawValue }
        voiceCache[locale] = v
        return v
    }

    func hasVoice(_ locale: String) -> Bool { voice(for: locale) != nil }

    func speak(_ text: String, locale: String) {
        guard let v = voice(for: locale) else { return }
        let s = synth ?? AVSpeechSynthesizer()
        synth = s
        s.stopSpeaking(at: .immediate)
        let u = AVSpeechUtterance(string: text)
        u.voice = v
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 0.9
        s.speak(u)
    }

    func stop() {
        synth?.stopSpeaking(at: .immediate)
        synth = nil
    }
}
