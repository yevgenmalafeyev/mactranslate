import Foundation

/// One-time carry-over of data stored under the app's former name ("MacTranslate"):
/// history database, settings (UserDefaults domain) and image API keys.
public enum LegacyMigration {
    static let oldBundleID = "local.mactranslate.app"
    static let oldFolder = "MacTranslate"
    static let doneKey = "migratedFromMacTranslate"

    public static func runIfNeeded() {
        let defaults = UserDefaults.standard
        removeKeyBearingCaches()
        guard !defaults.bool(forKey: doneKey) else { removeOldNameLeftovers(); return }

        // Settings: copy the old defaults domain, never overwriting values already set.
        if let old = defaults.persistentDomain(forName: oldBundleID) {
            for (k, v) in old where defaults.object(forKey: k) == nil { defaults.set(v, forKey: k) }
        }

        // History database and working files.
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let oldDir = support.appendingPathComponent(oldFolder, isDirectory: true)
        let newDir = support.appendingPathComponent("mTranslate", isDirectory: true)
        // Only a real folder is taken over (a link planted under the old name would redirect the history).
        if (try? fm.attributesOfItem(atPath: oldDir.path))?[.type] as? FileAttributeType == .typeDirectory {
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
        removeOldNameLeftovers()

        defaults.set(true, forKey: doneKey)
    }

    /// After the carry-over nothing stays behind under the old name: copied keys and the old settings.
    /// (Also runs on later launches, for installs migrated by a version that left them.)
    static func removeOldNameLeftovers() {
        for name in ["pexels", "pixabay"] where Keychain.get(name) != nil { Keychain.delete(service: "\(oldBundleID).\(name)") }
        if UserDefaults.standard.persistentDomain(forName: oldBundleID) != nil {
            UserDefaults.standard.removePersistentDomain(forName: oldBundleID)
        }
    }

    /// Earlier versions kept an on-disk HTTP cache of image-API calls, whose URLs contain the Pixabay key.
    /// It is no longer written; what exists (under the current and the former name) is removed at launch.
    static func removeKeyBearingCaches() {
        let fm = FileManager.default
        let lib = fm.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        for id in [oldBundleID, "local.mtranslate.app"] {
            let cache = lib.appendingPathComponent("Caches/\(id)", isDirectory: true)
            for f in ["Cache.db", "Cache.db-wal", "Cache.db-shm", "fsCachedData"] {
                try? fm.removeItem(at: cache.appendingPathComponent(f))
            }
        }
        for suffix in ["", ".binarycookies"] {
            try? fm.removeItem(at: lib.appendingPathComponent("HTTPStorages/\(oldBundleID)\(suffix)"))
        }
    }
}
