import Foundation
import mTranslateCore

// Usage: mtprobe "text" [--target ru] [--mono pt] [--card word] [--model sonnet] [--effort low] [--raw]
var args = Array(CommandLine.arguments.dropFirst())
@MainActor func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}
let target = opt("--target") ?? "ru"
let mono = opt("--mono")
let card = opt("--card")
let model = ClaudeModel(rawValue: opt("--model") ?? "sonnet") ?? .sonnet
let effort = opt("--effort")
let warm = Int(opt("--warm") ?? "0") ?? 0
let raw = args.contains("--raw")
args.removeAll { $0 == "--raw" }
guard let text = args.first else {
    print("usage: mtprobe \"text\" [--target ru] [--mono pt] [--card word] [--model sonnet] [--effort low] [--raw]")
    exit(2)
}
guard let bin = ClaudeLocator.locate(configured: nil) else { print("claude not found"); exit(1) }

let t0 = Date()
func ts() -> String { String(format: "%6.2fs", Date().timeIntervalSince(t0)) }

let system: String
let user: String
let tgt = LanguageRegistry.forCode(target)
if let card {
    let src = mono.map(LanguageRegistry.forCode)
    let tab: TabTarget = mono != nil ? .mono(src!) : .translate(tgt)
    system = Prompts.cardSystem(source: src, target: tab)
    user = Prompts.cardUser(word: card, sentence: text)
} else if let mono {
    system = Prompts.monoSystem(source: LanguageRegistry.forCode(mono), level: .B2)
    user = Prompts.snippetUser(text)
} else {
    system = Prompts.translationSystem(target: tgt, level: .B2)
    user = Prompts.snippetUser(text)
}

let req = ClaudeRequest(binary: bin, model: model, system: system, user: user, effort: effort)
if warm > 0 {
    // Measure warm-session latency: run the same task `warm` times through the pool.
    for i in 0..<warm {
        let s = Date(); var first: Double?; var out = ""
        for try await ev in await ClaudePool.shared.stream(binary: bin, model: model, system: system, user: user) {
            if case .text(let t) = ev { if first == nil { first = Date().timeIntervalSince(s) }; out += t }
        }
        print(String(format: "turn %d: first %.2fs total %.2fs", i, first ?? -1, Date().timeIntervalSince(s)))
        if i == warm - 1 { print(out) }
    }
    await ClaudePool.shared.closeAll()
    exit(0)
}
var sp = SnippetStreamParser()
var cp = CardStreamParser()
var firstDelta: Date?
do {
    for try await ev in ClaudeRunner().stream(req) {
        switch ev {
        case .text(let t):
            if firstDelta == nil { firstDelta = Date(); print("[\(ts())] first delta") }
            if raw { print("[\(ts())] Δ \(t.debugDescription)") }
            if card != nil {
                for e in cp.feed(t) { print("[\(ts())] \(e)") }
            } else {
                for e in sp.feed(t) {
                    if case .translationDelta(let d) = e { print("[\(ts())] T: \(d.debugDescription)") } else { print("[\(ts())] \(e)") }
                }
            }
        case .full: print("[\(ts())] (full message)")
        case .rateLimit(let s, let r, let u): print("[\(ts())] rate limit \(s) \(String(describing: r)) \(String(describing: u))")
        case .result(let e, let m): print("[\(ts())] result error=\(e) \(e ? (m ?? "") : "")")
        }
    }
    if card != nil { _ = cp.finish(); print("bad lines: \(cp.badLines), senses: \(cp.senses.count)") }
    else { _ = sp.finish(); print("lang=\(sp.language ?? "-") same=\(sp.isSame) words=\(sp.words.count) bad=\(sp.badLines)\n---\n\(sp.cleanTranslation)") }
} catch {
    print("[\(ts())] ERROR: \(error) — \(error.localizedDescription)")
}
print("total \(ts())")
