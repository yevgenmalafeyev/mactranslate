import Foundation

/// One-time carry-over of data stored under the app's former name ("MacTranslate"):
/// history database, settings (UserDefaults domain) and image API keys.
public enum LegacyMigration {
    static let oldBundleID = "local.mactranslate.app"
    static let oldFolder = "MacTranslate"
    static let doneKey = "migratedFromMacTranslate"

    public static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }

        // Settings: copy the old defaults domain, never overwriting values already set.
        if let old = defaults.persistentDomain(forName: oldBundleID) {
            for (k, v) in old where defaults.object(forKey: k) == nil { defaults.set(v, forKey: k) }
        }

        // History database and working files.
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent(oldFolder, isDirectory: true)
        let newDir = support.appendingPathComponent("mTranslate", isDirectory: true)
        if fm.fileExists(atPath: oldDir.path) {
            let newEmpty = (try? fm.contentsOfDirectory(atPath: newDir.path))?.isEmpty ?? true
            if newEmpty {
                try? fm.removeItem(at: newDir)
                try? fm.moveItem(at: oldDir, to: newDir)
            }
        }

        // Image API keys.
        for name in ["pexels", "pixabay"] where Keychain.get(name) == nil {
            if let v = Keychain.get(service: "\(oldBundleID).\(name)") { Keychain.set(name, v) }
        }

        defaults.set(true, forKey: doneKey)
    }
}
