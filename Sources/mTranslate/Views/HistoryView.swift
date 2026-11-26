import mTranslateCore
import SwiftUI

struct HistoryView: View {
    enum Kind: String, CaseIterable { case snippets = "Snippets", words = "Words" }

    @State private var kind: Kind = .snippets
    @State private var search = ""
    @State private var snippets: [SnippetRow] = []
    @State private var cards: [CardRow] = []

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $kind) {
                    ForEach(Kind.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                TextField("Search", text: $search)
                    .textFieldStyle(.roundedBorder)
            }
            .padding([.horizontal, .top], 12)

            List {
                switch kind {
                case .snippets:
                    ForEach(snippets) { r in
                        Button { PopupController.shared.present(text: r.text) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.text).lineLimit(2)
                                HStack {
                                    if let l = r.sourceLang { Text(LanguageRegistry.forCode(l).nativeName) }
                                    Text(r.lastUsed, style: .relative) + Text(" ago")
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete") { Task { try? await Store.shared.deleteSnippet(id: r.id); await reload() } }
                        }
                    }
                case .words:
                    ForEach(cards) { r in
                        Button { PopupController.shared.present(card: r) } label: {
                            HStack {
                                Text(r.lemma).fontWeight(.semibold)
                                Text(LanguageRegistry.forCode(r.sourceLang).nativeName).foregroundStyle(.secondary)
                                Text("→ " + targetName(r.target)).foregroundStyle(.secondary)
                                Spacer()
                                Text(r.lastUsed, style: .relative).font(.caption).foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button("Delete") {
                                Task {
                                    try? await Store.shared.deleteCard(lemma: r.lemma, sourceLang: r.sourceLang, target: r.target)
                                    await reload()
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 400)
        .task(id: "\(kind.rawValue)|\(search)") {
            try? await Task.sleep(for: .milliseconds(150))
            await reload()
        }
    }

    private func targetName(_ t: String) -> String {
        t.hasPrefix("mono:") ? "📖 " + LanguageRegistry.forCode(String(t.dropFirst(5))).nativeName : LanguageRegistry.forCode(t).nativeName
    }

    private func reload() async {
        switch kind {
        case .snippets: snippets = (try? await Store.shared.recentSnippets(search: search)) ?? []
        case .words: cards = (try? await Store.shared.recentCards(search: search)) ?? []
        }
    }
}
