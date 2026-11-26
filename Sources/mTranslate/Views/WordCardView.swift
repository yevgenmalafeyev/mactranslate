import mTranslateCore
import SwiftUI

struct WordCardView: View {
    @Bindable var job: CardJob
    let showBack: Bool
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if showBack {
                    Button(action: back) {
                        Label("Back", systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                    .help("Back (esc)")
                }
                Spacer()
                Text(job.target.isMono ? job.target.language.nativeName : "→ \(job.target.language.nativeName)")
                    .font(.system(size: fs(11)))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 30)
            .padding(.bottom, 6)

            ScrollViewReader { proxy in
                AutoGrowScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        header
                        if case .failed(let err) = job.status {
                            ErrorBanner(error: err) {}
                        }
                        if job.resolvingContext {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.mini)
                                Text("Finding the meaning used in your text…").font(.system(size: fs(11))).foregroundStyle(.secondary)
                            }
                        }
                        if !job.senses.isEmpty {
                            ImagePanel(job: job) { i in
                                job.userSelected = true
                                job.selectedSense = i
                                withAnimation { proxy.scrollTo("sense-\(i)", anchor: .top) }
                            }
                        }
                        ForEach(Array(job.senses.enumerated()), id: \.offset) { i, s in
                            SenseView(index: i, sense: s, selected: job.selectedSense == i,
                                      inContext: job.contextSense == i && !job.historyOnly,
                                      ttsLocale: job.source?.ttsLocale, mono: job.target.isMono)
                                .id("sense-\(i)")
                                .onTapGesture { job.userSelected = true; job.selectedSense = i }
                        }
                        if job.status == .loading || job.status == .streaming {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text(verbatim: job.head == nil ? "Looking up “\(job.surface)”…" : "Loading meanings…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 16)
                }
            }
        }
    }

    @ViewBuilder private var header: some View {
        if let h = job.head {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(h.lemma).font(.system(size: fs(26), weight: .bold)).textSelection(.enabled)
                    SpeakButton(text: h.lemma, locale: job.source?.ttsLocale)
                    if job.fromCache {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.tertiary).help("From history")
                    }
                }
                HStack(spacing: 8) {
                    if let ipa = h.ipa, !ipa.isEmpty { Text(ipa.hasPrefix("/") || ipa.hasPrefix("[") ? ipa : "/\(ipa)/").foregroundStyle(.secondary) }
                    if !h.pos.isEmpty { Tag(h.pos) }
                    if let g = h.gender, !g.isEmpty, g != "null" { Tag(genderLabel(g)) }
                }
                .font(.system(size: fs(13)))
                if let f = h.forms, !f.isEmpty {
                    Text(f).font(.system(size: fs(12))).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let n = h.note, !n.isEmpty {
                    Text(n).font(.system(size: fs(12))).italic().foregroundStyle(.secondary)
                }
            }
        } else {
            Text(job.surface).font(.system(size: fs(26), weight: .bold))
        }
    }

    private func genderLabel(_ g: String) -> String {
        switch g.lowercased() {
        case "m": "♂ masculine"
        case "f": "♀ feminine"
        case "n": "neuter"
        case "c": "common"
        default: g
        }
    }
}

struct Tag: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: fs(11), weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Color.secondary.opacity(0.15), in: Capsule())
    }
}

struct SenseView: View {
    let index: Int
    let sense: CardSense
    let selected: Bool
    let inContext: Bool
    let ttsLocale: String?
    let mono: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(index + 1).").font(.system(size: fs(14), weight: .bold)).foregroundStyle(.secondary)
                Text(sense.gloss).font(.system(size: fs(14), weight: .semibold))
                if inContext {
                    Label("in your text", systemImage: "text.cursor")
                        .font(.system(size: fs(10), weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            if !sense.tr.isEmpty {
                Text((mono ? "≈ " : "") + sense.tr.joined(separator: ", "))
                    .font(.system(size: fs(14)))
                    .foregroundStyle(Color.accentColor)
                    .textSelection(.enabled)
            }
            if !sense.def.isEmpty {
                Text(sense.def).font(.system(size: fs(13))).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(sense.ex.enumerated()), id: \.offset) { _, ex in
                HStack(alignment: .top, spacing: 6) {
                    SpeakButton(text: ex.s, locale: ttsLocale, small: true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ex.s).font(.system(size: fs(13))).italic().textSelection(.enabled)
                        if let t = ex.t, !t.isEmpty {
                            Text(t).font(.system(size: fs(12))).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Color.accentColor.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(inContext ? Color.accentColor : .clear, lineWidth: 1.5))
    }
}

struct SpeakButton: View {
    let text: String
    let locale: String?
    var small = false

    var body: some View {
        let available = locale.map { Speech.shared.hasVoice($0) } ?? false
        Button {
            if let locale { Speech.shared.speak(text, locale: locale) }
        } label: {
            Image(systemName: "speaker.wave.2.fill").font(.system(size: fs(small ? 10 : 14)))
        }
        .buttonStyle(.borderless)
        .disabled(!available)
        .help(available ? "Pronounce" : "No voice installed for this language")
    }
}

// MARK: Images

struct ImagePanel: View {
    @Bindable var job: CardJob
    let select: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            mainImage
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            if let hit = job.images[job.selectedSense]?.first {
                HStack {
                    Text(hit.credit).lineLimit(1)
                    Spacer()
                    if let page = hit.pageURL { Link("source", destination: page) }
                }
                .font(.system(size: fs(10)))
                .foregroundStyle(.tertiary)
            }
            if job.senses.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(job.senses.enumerated()), id: \.offset) { i, s in
                            Button { select(i) } label: {
                                VStack(spacing: 3) {
                                    thumb(i)
                                        .frame(width: 84, height: 56)
                                        .background(Color.secondary.opacity(0.08))
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(job.selectedSense == i ? Color.accentColor : .clear, lineWidth: 2))
                                    Text(verbatim: "\(i + 1). \(s.gloss)").font(.system(size: fs(10), weight: job.contextSense == i && !job.historyOnly ? .bold : .regular))
                                        .foregroundStyle(job.contextSense == i && !job.historyOnly ? Color.accentColor : .primary)
                                        .lineLimit(1).frame(width: 84)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(2)
                }
            }
        }
    }

    @ViewBuilder private var mainImage: some View {
        let i = job.selectedSense
        if let hit = job.images[i]?.first {
            RemoteImage(hit: hit) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFit()
                case .failure: placeholder(i)
                case .loading: ProgressView().controlSize(.small)
                }
            }
        } else if job.imagesLoading.contains(i) || (i < job.senses.count && job.images[i] == nil) {
            ProgressView().controlSize(.small)
        } else {
            placeholder(i)
        }
    }

    @ViewBuilder private func thumb(_ i: Int) -> some View {
        if let hit = job.images[i]?.first {
            RemoteImage(hit: hit) { phase in
                if case .success(let img) = phase { img.resizable().scaledToFill() } else { Color.clear }
            }
        } else {
            Image(systemName: i < job.senses.count && job.senses[i].abstract ? "lightbulb" : "photo")
                .foregroundStyle(.tertiary)
        }
    }

    private func placeholder(_ i: Int) -> some View {
        VStack(spacing: 6) {
            Image(systemName: i < job.senses.count && job.senses[i].abstract ? "lightbulb" : "photo")
                .font(.system(size: fs(28)))
            Text(i < job.senses.count && job.senses[i].abstract ? "Abstract meaning — no picture" : "No image found")
                .font(.system(size: fs(11)))
        }
        .foregroundStyle(.tertiary)
    }
}

/// A thumbnail loaded through `ImageService.thumbnail` (provider host only, no redirects, size-capped,
/// nothing cached on disk) instead of the system's general-purpose image loader.
enum RemoteImagePhase { case loading, success(Image), failure }

struct RemoteImage<Content: View>: View {
    typealias Phase = RemoteImagePhase

    let hit: ImageHit
    let content: (Phase) -> Content
    @State private var phase: Phase = .loading

    init(hit: ImageHit, @ViewBuilder content: @escaping (Phase) -> Content) {
        self.hit = hit
        self.content = content
    }

    var body: some View {
        content(phase)
            .task(id: hit.thumbURL) {
                phase = .loading
                if let cg = await ImageService.shared.thumbnail(hit) {
                    phase = .success(Image(decorative: cg, scale: 1))
                } else if !Task.isCancelled {
                    phase = .failure
                }
            }
    }
}
