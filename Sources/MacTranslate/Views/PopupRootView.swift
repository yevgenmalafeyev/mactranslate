import MacTranslateCore
import SwiftUI

struct PopupRootView: View {
    @Bindable var session: PopupSession
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch session.route {
            case .snippet:
                SnippetHomeView(session: session)
            case .card(let job):
                WordCardView(job: job, showBack: !session.cardOnly, back: { session.back() })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .ignoresSafeArea()
    }
}

struct SnippetHomeView: View {
    @Bindable var session: PopupSession

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                ClickableSnippet(session: session)
                    .padding(.horizontal, 18)
                    .padding(.top, 30)
                    .padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
            .fixedSize(horizontal: false, vertical: true)

            TabBarView(session: session)
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            Divider()

            if let tab = session.active, let job = session.jobs[tab.id] {
                TranslationTabView(session: session, job: job)
                    .id(tab.id)
            } else {
                Spacer()
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                Spacer()
            }
        }
    }
}

// MARK: Clickable snippet

struct ClickableSnippet: View {
    @Bindable var session: PopupSession

    var body: some View {
        Text(attributed)
            .font(.system(size: fs(15)))
            .lineSpacing(3)
            .tint(.primary)
            .environment(\.openURL, OpenURLAction { url in
                if url.scheme == "mt", let i = Int(url.lastPathComponent), i < session.tokens.count {
                    session.openCard(token: session.tokens[i])
                }
                return .handled
            })
            .help("Click a word for its full card")
    }

    private var attributed: AttributedString {
        let text = session.text
        let ns = text as NSString
        let listed = session.listedWords
        var out = AttributedString()
        var cursor = 0
        for (i, tok) in session.tokens.enumerated() {
            if tok.start > cursor {
                out += AttributedString(ns.substring(with: NSRange(location: cursor, length: tok.start - cursor)))
            }
            var w = AttributedString(tok.text)
            w.link = URL(string: "mt://w/\(i)")
            if listed.contains(tok.text.lowercased()) {
                w.underlineStyle = .single
                w.underlineColor = NSColor.controlAccentColor
            }
            out += w
            cursor = tok.end
        }
        if cursor < ns.length {
            out += AttributedString(ns.substring(from: cursor))
        }
        return out
    }
}

// MARK: Tabs

struct TabBarView: View {
    @Bindable var session: PopupSession

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(session.tabs.enumerated()), id: \.element.id) { i, tab in
                    let selected = session.active == tab
                    Button {
                        session.select(tab)
                    } label: {
                        HStack(spacing: 5) {
                            if tab.isMono { Image(systemName: "book").font(.system(size: fs(10))) }
                            Text(tab.language.nativeName)
                            if i < 9 {
                                Text("⌘\(i + 1)").font(.system(size: fs(10))).foregroundStyle(.tertiary)
                            }
                        }
                        .font(.system(size: fs(12), weight: selected ? .semibold : .regular))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(selected ? Color.accentColor.opacity(0.18) : .clear, in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help(tab.isMono ? "Explanation in \(tab.language.englishName)" : "Translation into \(tab.language.englishName)")
                }
            }
        }
    }
}

// MARK: Translation tab

struct TranslationTabView: View {
    @Bindable var session: PopupSession
    let job: TabJob

    var body: some View {
        VStack(spacing: 0) {
            AutoGrowScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if case .failed(let err) = job.status {
                        ErrorBanner(error: err) { session.retry(job.target) }
                    }
                    if job.translation.isEmpty, !job.isFinished {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(job.target.isMono ? "Explaining…" : "Translating…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    } else if !job.translation.isEmpty {
                        Text(job.translation)
                            .font(.system(size: fs(15)))
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !job.words.isEmpty {
                        Divider()
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(job.words) { w in
                                WordRow(entry: w, mono: job.target.isMono) { session.openCard(entry: w) }
                            }
                        }
                    } else if job.status == .streaming {
                        ProgressView().controlSize(.small)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            }
            FooterView(job: job)
        }
    }
}

struct WordRow: View {
    let entry: WordEntry
    let mono: Bool
    let open: () -> Void
    @State private var hover = false

    /// The first meaning is the one used in the snippet: highlight it.
    private var meanings: Text {
        var t = Text("")
        for (i, m) in entry.m.enumerated() {
            if i == 0 {
                t = t + Text("1. \(m)").foregroundColor(.accentColor).bold()
            } else {
                t = t + Text("   \(i + 1). \(m)").foregroundColor(.secondary)
            }
        }
        return t
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.w).font(.system(size: fs(14), weight: .semibold))
                    if entry.l.lowercased() != entry.w.lowercased() {
                        Text("← \(entry.l)").font(.system(size: fs(12))).foregroundStyle(.secondary)
                    }
                    if !entry.p.isEmpty {
                        Text(entry.p).font(.system(size: fs(11))).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: fs(10))).foregroundStyle(.tertiary).opacity(hover ? 1 : 0)
                }
                meanings
                    .font(.system(size: fs(13)))
                    .fixedSize(horizontal: false, vertical: true)
                if mono, let ex = entry.ex, !ex.isEmpty {
                    Text(ex).font(.system(size: fs(12))).italic().foregroundStyle(.tertiary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hover ? Color.primary.opacity(0.05) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct FooterView: View {
    let job: TabJob

    var body: some View {
        HStack(spacing: 10) {
            Text(job.model.title)
            if job.fromCache { Label("cached", systemImage: "clock.arrow.circlepath") }
            if let e = job.elapsed { Text(String(format: "%.1fs", e)) }
            if let r = job.rateNote { Text(r).foregroundStyle(.orange) }
            Spacer()
            if FontScale.shared.value != 1 {
                Text("text \(Int((FontScale.shared.value * 100).rounded()))% · ⌘0 to reset").foregroundStyle(.tertiary)
            }
            Text("esc to close").foregroundStyle(.tertiary)
        }
        .font(.system(size: fs(10)))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct ErrorBanner: View {
    let error: ClaudeError
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(error.localizedDescription).font(.system(size: fs(12))).textSelection(.enabled)
            Spacer()
            if error.isRetryable {
                Button("Retry", action: retry).controlSize(.small)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
