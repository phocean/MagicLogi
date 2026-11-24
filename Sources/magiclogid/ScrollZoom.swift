// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// Modifier + scroll = zoom ([zoom], off by default). Study and measurements:
// docs/etude-zoom.md.
//
// One active event tap, SCROLL EVENTS ONLY (never keyboard, clicks or
// motion), created only while [zoom] is enabled and Accessibility granted.
// It sits at the annotated session level: downstream of MagicTrackpoint's
// HID-level taps and of the scroll events it posts, so the TrackPoint works
// without any change there, and each event carries its target process.
// For each scroll event: modifier held alone, target application in the
// list, mostly vertical → the event is absorbed and ⌘= / ⌘- are sent to that
// process. Anything else goes on untouched. Nothing is logged about events.
//
// Fails safe: the tap belongs to this process and disappears with it (crash
// or stop); scrolling is then native again at once. A tap the system
// disables for being too slow is re-enabled.

import Foundation
import ApplicationServices
import Darwin
import MagicLogiCore

/// Bundle identifier of a process, from its executable path (Foundation
/// only, no AppKit). Cached by pid.
enum ProcessBundle {
    private static var cache: [pid_t: String] = [:]

    static func identifier(_ pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        if let id = cache[pid] { return id.isEmpty ? nil : id }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        var id = ""
        if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
            let path = String(cString: buf)
            // …/Name.app/Contents/MacOS/Name → …/Name.app
            if let r = path.range(of: ".app/", options: .backwards) {
                id = Bundle(path: String(path[..<r.lowerBound]) + ".app")?.bundleIdentifier ?? ""
            }
        }
        if cache.count > 256 { cache.removeAll() }   // pids are reused; keep it small
        cache[pid] = id
        return id.isEmpty ? nil : id
    }
}

final class ScrollZoom {
    private let injector: Injector
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var config = ZoomConfig()
    private var apps: Set<String> = []
    private var natural = true
    private var tracker = ZoomTracker()
    /// Called when the tap turns itself off (Accessibility withdrawn).
    var onLost: (() -> Void)?

    // View > Zoom In (⌘+) / Zoom Out (⌘-), sent by PHYSICAL key position
    // (ANSI "=" and "-" keys), not by character. macOS localizes menu key
    // equivalents to the keyboard layout by key position: in Aperçu with a
    // French AZERTY layout, Zoom Out is ⌘) — the key where QWERTY has "-".
    // Measured 2026-11-24: ⌘- (by character) zoomed a PDF out (PDFKit
    // handles it itself) but never an image, which only the menu zooms.
    private static let zoomIn = KeyCombo(keyCode: 0x18, modifiers: .command)    // kVK_ANSI_Equal
    private static let zoomOut = KeyCombo(keyCode: 0x1B, modifiers: .command)   // kVK_ANSI_Minus

    init(injector: Injector) { self.injector = injector }

    var isActive: Bool { tap != nil }

    /// Creates the tap, or updates its settings. False if it cannot be created
    /// (Accessibility missing).
    @discardableResult
    func start(_ config: ZoomConfig) -> Bool {
        self.config = config
        apps = Set(config.apps)
        natural = ScrollZoom.naturalScrolling()
        tracker.reset()
        if tap != nil { return true }
        let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, ctx in
                                            guard let ctx else { return Unmanaged.passUnretained(event) }
                                            return Unmanaged<ScrollZoom>.fromOpaque(ctx).takeUnretainedValue()
                                                .handle(type, event)
                                        }, userInfo: me) else {
            log.error("zoom: cannot create the scroll event tap (Accessibility)")
            return false
        }
        guard let src = CFMachPortCreateRunLoopSource(nil, t, 0) else {
            CFMachPortInvalidate(t)
            log.error("zoom: cannot schedule the scroll event tap")
            return false
        }
        // Common modes: also served while a HID++ exchange waits in the
        // default mode (LogiDevice.send).
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        runLoopSource = src
        log.notice("zoom: on (scroll events only), apps \(config.apps.joined(separator: ","), privacy: .public), natural scrolling \(self.natural ? "on" : "off", privacy: .public)")
        return true
    }

    func stop() {
        guard let t = tap else { return }
        CGEvent.tapEnable(tap: t, enable: false)
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        CFMachPortInvalidate(t)
        tap = nil
        runLoopSource = nil
        tracker.reset()
        log.notice("zoom: off")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .scrollWheel:
            break
        case .tapDisabledByTimeout:
            // We were too slow once: re-enable, forget the partial gesture.
            log.error("zoom: scroll tap disabled by the system (timeout), re-enabling")
            tracker.reset()
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            // tapDisabledByUserInput is sent when we disable it ourselves.
            return Unmanaged.passUnretained(event)
        }
        // Never act on our own events (we post none of this type; belt and braces).
        if event.getIntegerValueField(.eventSourceUserData) == Injector.marker { return Unmanaged.passUnretained(event) }

        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        var dy = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
        var dx = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
        if dy == 0 && dx == 0 {   // very small deltas: point fields round to 0
            dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) * 10
            dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2) * 10
        }
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        let decision = tracker.handle(held: KeyModifiers(eventFlags: event.flags),
                                      isTarget: { ProcessBundle.identifier(pid).map(apps.contains) ?? false },
                                      dy: dy, dx: dx, momentum: momentum,
                                      at: ProcessInfo.processInfo.systemUptime, config: config, natural: natural)
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .absorb(let steps):
            if steps != 0 {
                guard Injector.allowed else {
                    // Accessibility withdrawn: give scrolling back.
                    log.error("zoom: Accessibility withdrawn, zoom off")
                    stop()
                    DispatchQueue.main.async { [weak self] in self?.onLost?() }
                    return Unmanaged.passUnretained(event)
                }
                let combo = steps > 0 ? ScrollZoom.zoomIn : ScrollZoom.zoomOut
                log.debug("zoom: \(steps) step(s) to pid \(pid)")
                for _ in 0..<abs(steps) { injector.pressKeys(combo, toPid: pid) }
            }
            return nil
        }
    }

    /// macOS "natural scrolling" (absent key = on, the macOS default).
    static func naturalScrolling() -> Bool {
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        return (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                          kCFPreferencesAnyApplication) as? Bool) ?? true
    }
}
