import mTranslateCore
import SwiftUI

struct SettingsView: View {
    let trigger: TriggerMonitor
    @Bindable private var store = SettingsStore.shared
    @State private var pexelsKey = SettingsStore.shared.pexelsKey ?? ""
    @State private var pixabayKey = SettingsStore.shared.pixabayKey ?? ""
    @State private var claudeTest = ""
    @State private var testing = false

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            languages.tabItem { Label("Languages", systemImage: "globe") }
            translation.tabItem { Label("Translation", systemImage: "character.bubble") }
            images.tabItem { Label("Images", systemImage: "photo.on.rectangle") }
        }
        .padding(.top, 8)
        .frame(width: 560, height: 520)
    }

    private var general: some View {
        Form {
            Section("Trigger & popup") {
                Picker("Double ⌘C detection", selection: $store.s.triggerMode) {
                    ForEach(TriggerMode.allCases) { Text($0.title).tag($0) }
                }
                if store.s.triggerMode == .eventTap {
                    HStack {
                        Text("Input Monitoring: " + (trigger.tapActive ? "granted ✓" : "not granted"))
                            .foregroundStyle(trigger.tapActive ? Color.secondary : Color.orange)
                        Spacer()
                        if !trigger.tapActive {
                            Button("Open System Settings") { Permissions.request(); Permissions.openSettings() }
                        }
                    }
                }
                Stepper("Double-press window: \(store.s.doublePressMs) ms", value: $store.s.doublePressMs, in: 200...1000, step: 50)
                Picker("Popup position", selection: $store.s.popupPosition) {
                    ForEach(PopupPosition.allCases) { Text($0.title).tag($0) }
                }
            }

            Section("Startup") {
                Toggle("Launch at login", isOn: $store.s.launchAtLogin)
                Text("Login item: \(LoginItem.statusText)").font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var languages: some View {
        Form {
            Section("Languages") {
                Picker("Default language", selection: $store.s.defaultLanguage) {
                    ForEach(store.s.enabled) { Text($0.nativeName).tag($0.id) }
                }
                Picker("Second default (if snippet is in the default)", selection: $store.s.secondDefaultLanguage) {
                    ForEach(store.s.enabled) { Text($0.nativeName).tag($0.id) }
                }
                LanguageListEditor(enabled: $store.s.enabledLanguages)
                Text("European Portuguese is always used for Portuguese. The last tab always explains the snippet in its own language.")
                    .font(.caption).foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }

    private var translation: some View {
        Form {
            Section("Translation") {
                Picker("Model", selection: $store.s.model) {
                    ForEach(ClaudeModel.allCases) { Text($0.title).tag($0) }
                }
                Picker("Hide words known at level", selection: $store.s.level) {
                    ForEach(CEFRLevel.allCases) { Text($0.rawValue).tag($0) }
                }
                Toggle("Stream text as it arrives", isOn: $store.s.streaming)
                Toggle("Prefetch all tabs in parallel (≈5× more usage)", isOn: $store.s.prefetchAll)
                Stepper(store.s.keepWarmMinutes == 0 ? "Keep Claude warm: off (cold start every time)"
                                                     : "Keep Claude warm for \(store.s.keepWarmMinutes) min after last use",
                        value: $store.s.keepWarmMinutes, in: 0...60, step: 5)
                Text("A warm session answers ~0.5 s faster; it keeps up to 2 claude processes in memory while warm.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Claude CLI") {
                HStack {
                    TextField("", text: Binding(
                        get: { store.s.claudePath ?? "" },
                        set: { store.s.claudePath = $0.isEmpty ? nil : $0 }),
                              prompt: Text("Path to claude (empty = auto-detect)"))
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                    Button("Detect") {
                        let configured = store.s.claudePath
                        Task {
                            let u = await Task.detached { ClaudeLocator.locate(configured: configured) }.value
                            claudeTest = u.map { "Found: \($0.path)" } ?? "Not found"
                        }
                    }
                    Button(testing ? "Testing…" : "Test") { test() }.disabled(testing)
                }
                if !claudeTest.isEmpty {
                    Text(claudeTest).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var images: some View {
        Form {
            Section("Images") {
                Toggle("Pixabay (needs free API key)", isOn: $store.s.pixabayEnabled)
                LabeledContent("Pixabay API key") {
                    KeyField(provider: .pixabay, text: $pixabayKey, saved: store.pixabayKey) { store.pixabayKey = $0 }
                }
                Link("Get a key: log in at pixabay.com, then open pixabay.com/api/docs", destination: URL(string: "https://pixabay.com/api/docs/")!)
                    .font(.caption)
                Toggle("Pexels (needs API key; new keys currently paused)", isOn: $store.s.pexelsEnabled)
                LabeledContent("Pexels API key") {
                    KeyField(provider: .pexels, text: $pexelsKey, saved: store.pexelsKey) { store.pexelsKey = $0 }
                }
                Toggle("Wikipedia / Wikimedia Commons", isOn: $store.s.wikimediaEnabled)
                Toggle("Openverse (last resort)", isOn: $store.s.openverseEnabled)
            }

        }
        .formStyle(.grouped)
    }

    private func test() {
        testing = true
        claudeTest = ""
        let configured = store.s.claudePath
        let model = store.s.model
        Task {
            defer { testing = false }
            guard let bin = await Task.detached(operation: { ClaudeLocator.locate(configured: configured) }).value else {
                claudeTest = ClaudeError.cliNotFound.localizedDescription
                return
            }
            let started = Date()
            var text = ""
            do {
                let req = ClaudeRequest(binary: bin, model: model, system: "Reply with exactly: OK", user: "ping")
                for try await ev in ClaudeRunner().stream(req) {
                    if case .text(let t) = ev { text += t }
                    if case .result(true, let m) = ev { throw ClaudeError.classify(status: 1, text: m ?? "") }
                }
                claudeTest = "✓ \(bin.path) answered “\(text.trimmingCharacters(in: .whitespacesAndNewlines))” in \(String(format: "%.1f", Date().timeIntervalSince(started)))s"
            } catch {
                claudeTest = "✗ " + ((error as? ClaudeError)?.localizedDescription ?? error.localizedDescription)
            }
        }
    }
}

struct LanguageListEditor: View {
    @Binding var enabled: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Tabs (in order)").font(.callout)
            ForEach(Array(enabled.enumerated()), id: \.element) { i, id in
                HStack {
                    Text("\(i + 1). " + (LanguageRegistry.byId(id)?.nativeName ?? id))
                    Spacer()
                    Button { move(i, -1) } label: { Image(systemName: "chevron.up") }.disabled(i == 0)
                    Button { move(i, 1) } label: { Image(systemName: "chevron.down") }.disabled(i == enabled.count - 1)
                    Button { enabled.remove(at: i) } label: { Image(systemName: "minus.circle") }.disabled(enabled.count <= 2)
                }
                .buttonStyle(.borderless)
            }
            let available = LanguageRegistry.all.filter { !enabled.contains($0.id) }
            if !available.isEmpty {
                Menu("Add language") {
                    ForEach(available) { l in Button(l.nativeName + " — " + l.englishName) { enabled.append(l.id) } }
                }
                .fixedSize()
            }
        }
    }

    private func move(_ i: Int, _ d: Int) {
        let j = i + d
        guard j >= 0, j < enabled.count else { return }
        enabled.swapAt(i, j)
    }
}

/// Key entry that verifies the key against the provider before saving it.
struct KeyField: View {
    enum Check: Equatable { case idle, checking, valid, invalid(String) }

    let provider: KeyedImageProvider
    @Binding var text: String
    let saved: String?
    let save: (String?) -> Void
    @State private var check: Check = .idle

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        HStack(spacing: 8) {
            SecureField("", text: $text, prompt: Text("paste key here"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 220)
                .onSubmit(verifyAndSave)
                .onChange(of: text) { if check != .checking { check = .idle } }
            status.frame(width: 18)
            Button("Save", action: verifyAndSave)
                .disabled(check == .checking || trimmed == (saved ?? ""))
        }
        .task {
            // Re-check an already stored key so the tick reflects reality.
            guard let saved, trimmed == saved else { return }
            check = .checking
            let r = await ImageService.shared.validate(provider, key: saved)
            if trimmed == saved {
                switch r {
                case .ok: check = .valid
                case .rejected(let why), .unreachable(let why): check = .invalid(why)
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch check {
        case .idle:
            Color.clear
        case .checking:
            ProgressView().controlSize(.small)
        case .valid:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Key works — saved")
        case .invalid(let why):
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help(why)
        }
    }

    private func verifyAndSave() {
        let key = trimmed
        guard key != (saved ?? "") else { return }
        if key.isEmpty {
            // Clearing the field removes the stored key.
            save(nil)
            check = .idle
            return
        }
        check = .checking
        Task {
            let result = await ImageService.shared.validate(provider, key: key)
            guard trimmed == key else { return }  // edited meanwhile
            switch result {
            case .ok:
                save(key)
                check = .valid
            case .rejected(let why), .unreachable(let why):
                check = .invalid(why)
            }
        }
    }
}
