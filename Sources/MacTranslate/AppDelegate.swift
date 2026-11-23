import AppKit
import MacTranslateCore
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let trigger = TriggerMonitor()
    private var permissionOK = true
    private var settingsWindow: NSWindow?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        trigger.onTrigger = { text in PopupController.shared.present(text: text) }
        trigger.onPermissionChange = { [weak self] ok in
            self?.permissionOK = ok
            self?.updateIcon()
        }
        trigger.start()
        configurePool(SettingsStore.shared.s)

        SettingsStore.shared.onChange = { [weak self] old, new in
            guard let self else { return }
            if old.triggerMode != new.triggerMode || old.doublePressMs != new.doublePressMs { self.trigger.start() }
            if old.launchAtLogin != new.launchAtLogin { LoginItem.set(new.launchAtLogin) }
            if old.claudePath != new.claudePath { JobCenter.shared.resetBinary(); Task { await ClaudePool.shared.closeAll() } }
            if old.keepWarmMinutes != new.keepWarmMinutes || old.model != new.model { self.configurePool(new) }
        }

        // First run: register login item if installed in an Applications folder.
        var s = SettingsStore.shared.s
        if !s.didInitialLoginRegistration {
            if Bundle.main.bundlePath.contains("/Applications/"), s.launchAtLogin { LoginItem.set(true) }
            s.didInitialLoginRegistration = true
            SettingsStore.shared.s = s
        }
    }

    private func configurePool(_ s: AppSettings) {
        Task { await ClaudePool.shared.configure(keepWarmMinutes: s.keepWarmMinutes, maxSessions: 2) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        PopupController.shared.bringToFront()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        JobCenter.shared.cancelAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls where u.scheme == "mactranslate" {
            if u.host == "settings" { openSettings(); continue }
            if u.host == "history" { openHistory(); continue }
            let text = URLComponents(url: u, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value
            if let text { PopupController.shared.present(text: text) }
        }
    }

    private func updateIcon() {
        statusItem?.button?.image = Self.menuBarIcon(warning: !permissionOK)
    }

    /// Template icon matching the app icon: an outlined "A" bubble behind a solid "Я" bubble.
    static func menuBarIcon(warning: Bool) -> NSImage {
        let img = NSImage(size: NSSize(width: 22, height: 18), flipped: false) { _ in
            let back = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 6.5, width: 11, height: 9.5), xRadius: 3, yRadius: 3)
            back.lineWidth = 1.4
            NSColor.black.setStroke()
            back.stroke()
            let a = NSAttributedString(string: "A", attributes: [.font: NSFont.systemFont(ofSize: 7.5, weight: .heavy),
                                                                 .foregroundColor: NSColor.black])
            a.draw(at: NSPoint(x: 7 - a.size().width / 2, y: 11.2 - a.size().height / 2))
            let front = NSBezierPath(roundedRect: NSRect(x: 8, y: 1, width: 13, height: 10.5), xRadius: 3, yRadius: 3)
            // Clear a gap around the front bubble, then fill it.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(roundedRect: NSRect(x: 6.8, y: -0.2, width: 15.4, height: 12.9), xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            front.fill()
            let ya = NSAttributedString(string: warning ? "!" : "Я", attributes: [.font: NSFont.systemFont(ofSize: 8.5, weight: .heavy),
                                                                                  .foregroundColor: NSColor.black])
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            ya.draw(at: NSPoint(x: 14.5 - ya.size().width / 2, y: 6.25 - ya.size().height / 2))
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "MacTranslate"
        return img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if SettingsStore.shared.s.triggerMode == .eventTap && !trigger.tapActive {
            let warn = NSMenuItem(title: "⚠︎ Grant Input Monitoring…", action: #selector(grantPermission), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
            let relaunch = NSMenuItem(title: "Relaunch", action: #selector(relaunch), keyEquivalent: "")
            relaunch.target = self
            menu.addItem(relaunch)
            menu.addItem(.separator())
        }
        let clip = NSMenuItem(title: "Translate Clipboard", action: #selector(translateClipboard), keyEquivalent: "")
        clip.target = self
        menu.addItem(clip)
        let hist = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "")
        hist.target = self
        menu.addItem(hist)
        let conf = NSMenuItem(title: "Configuration…", action: #selector(openSettings), keyEquivalent: ",")
        conf.target = self
        menu.addItem(conf)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit MacTranslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc private func grantPermission() {
        Permissions.request()
        Permissions.openSettings()
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? p.run()
        NSApp.terminate(nil)
    }

    @objc private func translateClipboard() {
        if let s = TriggerMonitor.text(from: .general) { PopupController.shared.present(text: s) }
    }

    @objc func openSettings() {
        settingsWindow = showWindow(settingsWindow, title: "MacTranslate Configuration", size: NSSize(width: 560, height: 520)) {
            AnyView(SettingsView(trigger: self.trigger))
        }
    }

    @objc func openHistory() {
        historyWindow = showWindow(historyWindow, title: "MacTranslate History", size: NSSize(width: 620, height: 560)) {
            AnyView(HistoryView())
        }
    }

    private func showWindow(_ existing: NSWindow?, title: String, size: NSSize, content: () -> AnyView) -> NSWindow {
        if let w = existing, w.isVisible {
            NSApp.activate()
            w.makeKeyAndOrderFront(nil)
            return w
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.identifier = NSUserInterfaceItemIdentifier("mt.window")
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: content())
        w.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            // Release SwiftUI content when closed to keep idle memory low.
            (n.object as? NSWindow)?.contentView = nil
            DispatchQueue.main.async { Dock.update() }
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        return w
    }

    /// Edit menu so ⌘C/⌘V/⌘A work in text fields of this accessory app.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit MacTranslate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        let winItem = NSMenuItem()
        main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        winItem.submenu = win
        NSApp.mainMenu = main
    }
}

enum LoginItem {
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            log.error("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)")
        }
    }

    static var statusText: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "needs approval in System Settings → General → Login Items"
        case .notRegistered: "not registered"
        case .notFound: "not found (install the app to ~/Applications)"
        @unknown default: "unknown"
        }
    }
}
