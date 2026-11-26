import Foundation
import mTranslateCore
import Observation

@MainActor @Observable
final class SettingsStore {
    static let shared = SettingsStore()
    private static let key = "settings.v1"

    var s: AppSettings {
        didSet {
            guard s != oldValue else { return }
            if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: Self.key) }
            onChange?(oldValue, s)
        }
    }

    /// Cached API keys (Keychain is read once).
    var pexelsKey: String? {
        didSet { Keychain.set("pexels", pexelsKey) }
    }
    var pixabayKey: String? {
        didSet { Keychain.set("pixabay", pixabayKey) }
    }

    @ObservationIgnored var onChange: ((AppSettings, AppSettings) -> Void)?

    private init() {
        if let d = UserDefaults.standard.data(forKey: Self.key), let v = try? JSONDecoder().decode(AppSettings.self, from: d) {
            s = v
        } else {
            s = AppSettings()
        }
        pexelsKey = Keychain.get("pexels")
        pixabayKey = Keychain.get("pixabay")
    }

    var imageProviders: ImageProviders {
        ImageProviders(pixabayKey: pixabayKey, pixabay: s.pixabayEnabled, pexelsKey: pexelsKey, pexels: s.pexelsEnabled, wikimedia: s.wikimediaEnabled, openverse: s.openverseEnabled)
    }
}
