import AppKit
import CoreGraphics
import mTranslateCore

enum Permissions {
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }
    static func request() { _ = CGRequestListenEventAccess() }
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(u)
        }
    }
}

/// Detects a fast double ⌘C and hands over the copied text.
import Observation

@MainActor @Observable
final class TriggerMonitor {
    var onTrigger: ((String) -> Void)?
    var onPermissionChange: ((Bool) -> Void)?

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var retryTimer: Timer?
    private var clipTimer: Timer?
    private var lastPress: UInt64 = 0
    private var changeCountAtFirst = 0
    private var lastClipChange: (time: Date, count: Int, text: String?)?
    private var lastSeenCount = 0
    private(set) var tapActive = false

    private var settings: AppSettings { SettingsStore.shared.s }
    private var windowNs: UInt64 { UInt64(max(150, settings.doublePressMs)) * 1_000_000 }

    func start() {
        stop()
        switch settings.triggerMode {
        case .eventTap:
            if !startTap() {
                // Ask the system only once; afterwards the menu shows a "Grant Input Monitoring…" item.
                if !UserDefaults.standard.bool(forKey: "requestedListenAccess") {
                    UserDefaults.standard.set(true, forKey: "requestedListenAccess")
                    Permissions.request()
                }
                onPermissionChange?(false)
                retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        if self.startTap() {
                            self.retryTimer?.invalidate()
                            self.retryTimer = nil
                            self.onPermissionChange?(true)
                        }
                    }
                }
            } else {
                onPermissionChange?(true)
            }
        case .clipboard:
            lastSeenCount = NSPasteboard.general.changeCount
            let t = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pollClipboard() }
            }
            t.tolerance = 0.04
            RunLoop.main.add(t, forMode: .common)
            clipTimer = t
            onPermissionChange?(true)
        }
    }

    func stop() {
        retryTimer?.invalidate(); retryTimer = nil
        clipTimer?.invalidate(); clipTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        tapActive = false
    }

    // MARK: Event tap

    private func startTap() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let cb: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let me = Unmanaged<TriggerMonitor>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { me.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                        eventsOfInterest: mask, callback: cb,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tapActive = true
        log.info("event tap active")
        return true
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .keyDown,
              e.getIntegerValueField(.keyboardEventKeycode) == 8,
              e.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              e.flags.intersection([.maskCommand, .maskShift, .maskControl, .maskAlternate]) == .maskCommand
        else { return }
        let now = e.timestamp
        if lastPress != 0, now > lastPress, now - lastPress <= windowNs {
            lastPress = 0
            readPasteboard(baseline: changeCountAtFirst)
        } else {
            lastPress = now
            changeCountAtFirst = NSPasteboard.general.changeCount
        }
    }

    /// Wait for the copy to land (changeCount differs from the pre-copy value), then read text.
    private func readPasteboard(baseline: Int) {
        Task { @MainActor in
            let pb = NSPasteboard.general
            var waited = 0
            while pb.changeCount == baseline && waited < 500 {
                try? await Task.sleep(for: .milliseconds(20))
                waited += 20
            }
            guard pb.changeCount != baseline else { log.info("double copy without clipboard change"); return }
            try? await Task.sleep(for: .milliseconds(60))
            if let s = Self.text(from: pb) { onTrigger?(s) }
        }
    }

    static func text(from pb: NSPasteboard) -> String? {
        let types = pb.types ?? []
        let concealed = types.contains { ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"].contains($0.rawValue) }
        guard !concealed, let s = pb.string(forType: .string),
              !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }
        return s
    }

    // MARK: Clipboard watch

    private func pollClipboard() {
        let pb = NSPasteboard.general
        let c = pb.changeCount
        guard c != lastSeenCount else { return }
        lastSeenCount = c
        // nil for passwords and other concealed / transient items: those are never read.
        let text = Self.text(from: pb)
        let now = Date()
        if let prev = lastClipChange, now.timeIntervalSince(prev.time) * 1000 <= Double(settings.doublePressMs) + 150,
           prev.text == text, let s = text {
            lastClipChange = nil
            onTrigger?(s)
        } else {
            lastClipChange = (now, c, text)
        }
    }
}
