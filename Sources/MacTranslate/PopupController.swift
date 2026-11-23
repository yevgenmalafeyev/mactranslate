import AppKit
import MacTranslateCore
import SwiftUI

final class PopupPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                   styleMask: [.nonactivatingPanel, .titled, .closable, .fullSizeContentView, .resizable],
                   backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        minSize = NSSize(width: 420, height: 320)
        for b in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            standardWindowButton(b)?.isHidden = true
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, keyHandler?(e) == true { return }
        super.sendEvent(e)
    }
}

@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    static let shared = PopupController()

    private var panel: PopupPanel?
    private(set) var session: PopupSession?
    private var previousApp: NSRunningApplication?
    private let sizeKey = "popupSize"

    private func makePanel() -> PopupPanel {
        let p = PopupPanel()
        p.delegate = self
        p.keyHandler = { [weak self] e in self?.handleKey(e) ?? false }
        return p
    }

    /// The user's preferred size (saved only when they resize by hand). Auto-grown size is not remembered.
    private var baseSize: NSSize? {
        guard let s = UserDefaults.standard.string(forKey: sizeKey) else { return nil }
        let size = NSSizeFromString(s)
        return size.width >= 420 && size.height >= 320 ? size : nil
    }

    /// Grow the popup so content fits, as far as the screen allows.
    func grow(by delta: CGFloat) {
        guard let panel, panel.isVisible, !panel.inLiveResize,
              let vf = (panel.screen ?? NSScreen.main)?.visibleFrame.insetBy(dx: 0, dy: 12)
        else { return }
        var f = panel.frame
        let newH = min(f.height + ceil(delta), vf.height)
        guard newH > f.height + 1 else { return }
        let extra = newH - f.height
        if SettingsStore.shared.s.popupPosition == .center {
            f.origin.y -= extra / 2
        } else {
            f.origin.y -= extra  // keep the top edge in place
        }
        f.size.height = newH
        if f.minY < vf.minY { f.origin.y = vf.minY }
        if f.maxY > vf.maxY { f.origin.y = vf.maxY - f.height }
        panel.setFrame(f, display: true, animate: false)
    }

    func present(text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let clipped = t.count > 2000 ? String(t.prefix(2000)) : t
        let s = PopupSession(text: clipped)
        show(session: s)
        Task { await s.start() }
    }

    func present(card row: CardRow) {
        let s = PopupSession(text: row.lemma)
        s.cardOnly = true
        let target: TabTarget = row.target.hasPrefix("mono:")
            ? .mono(LanguageRegistry.forCode(String(row.target.dropFirst(5))))
            : .translate(LanguageRegistry.forCode(row.target))
        s.source = LanguageRegistry.forCode(row.sourceLang)
        s.active = target
        s.route = .card(JobCenter.shared.cachedCard(lemma: row.lemma, sourceLang: row.sourceLang, target: target))
        show(session: s)
    }

    private func show(session s: PopupSession) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        session = s
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if let base = baseSize { panel.setContentSize(base) } else { panel.setContentSize(NSSize(width: 640, height: 560)) }
        let host = NSHostingView(rootView: PopupRootView(session: s, close: { [weak self] in self?.hide() })
            .environment(\.growPopup) { [weak self] d in self?.grow(by: d) })
        host.sizingOptions = []
        panel.contentView = host
        position(panel)
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
        position(panel)
        Dock.update()
    }

    /// Dock icon / ⌘-Tab brought the app forward: show the popup again.
    func bringToFront() {
        guard let panel, panel.isVisible else { return }
        panel.level = .floating
        panel.makeKeyAndOrderFront(nil)
    }

    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        var f = panel.frame
        f.size.width = min(f.width, vf.width - 40)
        f.size.height = min(f.height, vf.height - 40)
        switch SettingsStore.shared.s.popupPosition {
        case .center:
            f.origin = NSPoint(x: vf.midX - f.width / 2, y: vf.midY - f.height / 2)
        case .nearCursor:
            f.origin = NSPoint(x: mouse.x + 12, y: mouse.y - f.height - 12)
            f.origin.x = max(vf.minX + 8, min(f.origin.x, vf.maxX - f.width - 8))
            f.origin.y = max(vf.minY + 8, min(f.origin.y, vf.maxY - f.height - 8))
        }
        panel.setFrame(f, display: true)
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        panel.contentView = nil
        session = nil
        Speech.shared.stop()
        Dock.update()
        // Jobs keep running in JobCenter and save to history when done.
        if NSApp.isActive, let prev = previousApp, !prev.isTerminated {
            prev.activate()
        }
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    // MARK: Keys

    private func handleKey(_ e: NSEvent) -> Bool {
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if e.keyCode == 53 { // ESC
            escape()
            return true
        }
        guard flags.contains(.command) else { return false }
        let ch = e.charactersIgnoringModifiers ?? ""
        if let d = Int(ch), (1...9).contains(d), let s = session {
            s.select(index: d - 1)
            return true
        }
        // Physical key codes so shortcuts work on Cyrillic layouts too.
        switch e.keyCode {
        case 24, 69: FontScale.shared.bigger(); return true   // ⌘= / ⌘+ (and keypad +)
        case 27, 78: FontScale.shared.smaller(); return true  // ⌘- (and keypad -)
        case 29, 82: FontScale.shared.reset(); return true    // ⌘0 (and keypad 0)
        case 13: hide(); return true                        // ⌘W
        case 33: session?.back(); return true                // ⌘[
        case 8: NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil); return true      // ⌘C
        case 0: NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil); return true // ⌘A
        default: return false
        }
    }

    private func escape() {
        guard let s = session else { hide(); return }
        if case .card = s.route, !s.cardOnly {
            s.back()
        } else {
            hide()
        }
    }

    // MARK: NSWindowDelegate

    /// Clicking another app keeps the popup open (it stays in the Dock) but lets it fall behind.
    func windowDidResignKey(_ notification: Notification) {
        panel?.level = .normal
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        if let panel { UserDefaults.standard.set(NSStringFromSize(panel.contentLayoutRect.size), forKey: sizeKey) }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }
}

/// Shows the Dock icon while any MacTranslate window is visible; menu-bar only otherwise.
@MainActor
enum Dock {
    static func update() {
        DispatchQueue.main.async {
            let visible = NSApp.windows.contains { w in
                w.isVisible && (w is PopupPanel || w.identifier?.rawValue == "mt.window")
            }
            let want: NSApplication.ActivationPolicy = visible ? .regular : .accessory
            if NSApp.activationPolicy() != want { NSApp.setActivationPolicy(want) }
        }
    }
}
