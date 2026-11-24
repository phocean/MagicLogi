// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// Modifier + left-button drag = move the document ([pan], off by default).
//
// One active event tap, LEFT-BUTTON EVENTS ONLY (press, drag, release:
// never keyboard, other buttons, plain motion or scrolling), created only
// while [pan] is enabled and Accessibility granted. Same level as the zoom
// tap (annotated session), so each event carries its target process.
// A press made with the modifier held alone over a listed application is
// taken whole: the application sees neither the press, the drags nor the
// release, and each drag is sent to it as a pixel scroll of the same
// distance, posted to the session at the pointer (the content follows
// the pointer, as with two fingers on a trackpad). Every other press goes on untouched. Nothing is logged about
// events.
//
// Fails safe: the tap belongs to this process and disappears with it. If it
// goes in the middle of a drag, the application at worst receives a release
// without a press, which it ignores.

import Foundation
import ApplicationServices
import MagicLogiCore

final class DragPan {
    private let injector: Injector
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var config = PanConfig()
    private var apps: Set<String> = []
    private var tracker = PanTracker()
    private var scrolls = 0
    private var total = (h: 0.0, v: 0.0)
    /// Called when the tap turns itself off (Accessibility withdrawn).
    var onLost: (() -> Void)?

    init(injector: Injector) { self.injector = injector }

    var isActive: Bool { tap != nil }

    /// Creates the tap, or updates its settings. False if it cannot be created
    /// (Accessibility missing).
    @discardableResult
    func start(_ config: PanConfig) -> Bool {
        self.config = config
        apps = Set(config.apps)
        if tap != nil { return true }
        let mask = [CGEventType.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let t = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, ctx in
                                            guard let ctx else { return Unmanaged.passUnretained(event) }
                                            return Unmanaged<DragPan>.fromOpaque(ctx).takeUnretainedValue()
                                                .handle(type, event)
                                        }, userInfo: me) else {
            log.error("pan: cannot create the left-button event tap (Accessibility)")
            return false
        }
        guard let src = CFMachPortCreateRunLoopSource(nil, t, 0) else {
            CFMachPortInvalidate(t)
            log.error("pan: cannot schedule the left-button event tap")
            return false
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tap = t
        runLoopSource = src
        log.notice("pan: on (left-button events only), apps \(config.apps.joined(separator: ","), privacy: .public)")
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
        log.notice("pan: off")
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let input: PanTracker.Input
        switch type {
        case .leftMouseDown:
            input = .down
        case .leftMouseDragged:
            input = .dragged(dx: Double(event.getIntegerValueField(.mouseEventDeltaX)),
                             dy: Double(event.getIntegerValueField(.mouseEventDeltaY)))
        case .leftMouseUp:
            input = .up
        case .tapDisabledByTimeout:
            log.error("pan: left-button tap disabled by the system (timeout), re-enabling")
            tracker.reset()
            if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
        // Our own clicks (a button set to "middle-click"… never left, but
        // belt and braces) are never taken.
        if event.getIntegerValueField(.eventSourceUserData) == Injector.marker { return Unmanaged.passUnretained(event) }

        let pid = pid_t(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID))
        let decision = tracker.handle(input, held: KeyModifiers(eventFlags: event.flags),
                                      isTarget: { ProcessBundle.identifier(pid).map(apps.contains) ?? false },
                                      config: config)
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .absorb:
            if case .down = input {
                guard Injector.allowed else {
                    log.error("pan: Accessibility withdrawn, pan off")
                    stop()
                    DispatchQueue.main.async { [weak self] in self?.onLost?() }
                    return Unmanaged.passUnretained(event)
                }
                scrolls = 0
                total = (0, 0)
                log.debug("pan: press taken (pid \(pid))")
            } else if case .up = input {
                log.debug("pan: release, \(self.scrolls) scroll event(s), total h \(self.total.h) v \(self.total.v)")
            }
            return nil
        case .scroll(let v, let h):
            injector.scroll(vertical: v, horizontal: h)
            scrolls += 1
            total.h += h; total.v += v
            return nil
        }
    }
}

extension KeyModifiers {
    /// The four keyboard modifiers of an event (fn and caps lock ignored).
    init(eventFlags f: CGEventFlags) {
        self = []
        if f.contains(.maskCommand) { insert(.command) }
        if f.contains(.maskAlternate) { insert(.option) }
        if f.contains(.maskControl) { insert(.control) }
        if f.contains(.maskShift) { insert(.shift) }
    }
}
