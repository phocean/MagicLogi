// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// `magiclogid scroll-probe`: diagnostic for the ⌘ + scroll zoom study
// (docs/etude-zoom.md, step 0). A LISTEN-ONLY event tap on scroll events, at
// the annotated session level (downstream of MagicTrackpoint's HID-level taps
// and of the scroll events it posts). Each scroll event is printed: deltas,
// phases, marker, source and target process, modifier state. Nothing is
// modified, absorbed or logged; keyboard events are never tapped (only the
// modifier flags are read).
//
// With --try-zoom[=equal|plus], when ⌘ is held over Aperçu (com.apple.Preview),
// it also sends ⌘= / ⌘- (or ⌘⇧= / ⌘-) to Aperçu's process with
// CGEventPostToPid, at most one every 150 ms: tests whether Aperçu zooms when
// not frontmost, and with which key on the current keyboard layout. The
// scroll itself still reaches Aperçu (listen-only).

import Foundation
import ApplicationServices
import Darwin
import MagicLogiCore

private struct ProbeState {
    var tap: CFMachPort?
    var start = Date()
    var bundles: [pid_t: String] = [:]
    var tryZoom = false
    var zoomInShift = false
    var injector: Injector?
    var zoomIn: KeyCombo?
    var zoomOut: KeyCombo?
    var lastZoom = Date.distantPast
    var count = 0
}

private var probe = ProbeState()

private let mtpMarker: Int64 = 0x4D54_504B   // "MTPK", MagicTrackpoint

private func bundleID(_ pid: pid_t) -> String {
    if pid <= 0 { return "-" }
    if let b = probe.bundles[pid] { return b }
    var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
    var id = "pid-only"
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
        let path = String(cString: buf)
        // …/Name.app/Contents/MacOS/Name → …/Name.app
        if let r = path.range(of: ".app/", options: .backwards) {
            let app = String(path[..<r.lowerBound]) + ".app"
            id = Bundle(path: app)?.bundleIdentifier ?? (app as NSString).lastPathComponent
        } else {
            id = (path as NSString).lastPathComponent
        }
    }
    probe.bundles[pid] = id
    return id
}

private func modifiers(_ f: CGEventFlags) -> String {
    var s: [String] = []
    if f.contains(.maskCommand) { s.append("cmd") }
    if f.contains(.maskAlternate) { s.append("alt") }
    if f.contains(.maskControl) { s.append("ctrl") }
    if f.contains(.maskShift) { s.append("shift") }
    return s.isEmpty ? "none" : s.joined(separator: "+")
}

private func tag(_ v: Int64) -> String {
    switch v {
    case 0: return "-"
    case mtpMarker: return "MTPK"
    case Injector.marker: return "MLOG"
    default: return String(format: "0x%llx", v)
    }
}

private func postZoom(_ pid: pid_t, zoomIn: Bool) {
    guard let combo = zoomIn ? probe.zoomIn : probe.zoomOut else { return }
    var flags: CGEventFlags = .maskCommand
    if zoomIn && probe.zoomInShift { flags.insert(.maskShift) }
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(combo.keyCode), keyDown: down) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: Injector.marker)
        e.postToPid(pid)
    }
    print("    -> sent \(zoomIn ? (probe.zoomInShift ? "cmd+shift+=" : "cmd+=") : "cmd+-") (key code 0x\(String(combo.keyCode, radix: 16))) to pid \(pid)")
}

private let probeCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout {
        print("tap disabled by the system (timeout), re-enabling")
        if let t = probe.tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
    probe.count += 1
    let g = { (f: CGEventField) in event.getIntegerValueField(f) }
    let d = { (f: CGEventField) in event.getDoubleValueField(f) }
    let target = pid_t(truncatingIfNeeded: g(.eventTargetUnixProcessID))
    let source = pid_t(truncatingIfNeeded: g(.eventSourceUnixProcessID))
    let state = CGEventSource.flagsState(.combinedSessionState)
    let t = Date().timeIntervalSince(probe.start)
    let line = String(format: "%7.3fs", t)
        + "  to \(target) \(bundleID(target))"
        + "  from \(source) \(bundleID(source))"
        + "  tag \(tag(g(.eventSourceUserData)))"
        + "  cont \(g(.scrollWheelEventIsContinuous))"
        + "  phase \(g(.scrollWheelEventScrollPhase))/\(g(.scrollWheelEventMomentumPhase))"
        + "  lines \(g(.scrollWheelEventDeltaAxis1))/\(g(.scrollWheelEventDeltaAxis2))"
        + "  pts \(g(.scrollWheelEventPointDeltaAxis1))/\(g(.scrollWheelEventPointDeltaAxis2))"
        + String(format: "  fixed %.2f/%.2f", d(.scrollWheelEventFixedPtDeltaAxis1), d(.scrollWheelEventFixedPtDeltaAxis2))
        + "  evflags \(modifiers(event.flags))  state \(modifiers(state))"
    print(line)

    if probe.tryZoom, state.contains(.maskCommand), bundleID(target) == "com.apple.Preview",
       Date().timeIntervalSince(probe.lastZoom) > 0.15 {
        let dy = g(.scrollWheelEventPointDeltaAxis1), dx = g(.scrollWheelEventPointDeltaAxis2)
        if dy != 0 && abs(dy) >= abs(dx) {
            probe.lastZoom = Date()
            postZoom(target, zoomIn: dy > 0)
        }
    }
    return Unmanaged.passUnretained(event)
}

func runScrollProbe(args: [String]) -> Int32 {
    var seconds: TimeInterval = 30
    for a in args {
        if a == "--try-zoom" || a == "--try-zoom=equal" { probe.tryZoom = true }
        else if a == "--try-zoom=plus" { probe.tryZoom = true; probe.zoomInShift = true }
        else if let s = TimeInterval(a), s > 0, s <= 300 { seconds = s }
        else { print("usage: magiclogid scroll-probe [SECONDS] [--try-zoom[=equal|plus]]"); return 64 }
    }
    setvbuf(stdout, nil, _IOLBF, 0)
    guard CGPreflightListenEventAccess() else {
        print("Input Monitoring not granted to magiclogid: run this through `magiclogictl scroll-probe`")
        return 1
    }
    if probe.tryZoom {
        guard Injector.allowed else { print("--try-zoom needs the Accessibility permission"); return 1 }
        let inj = Injector()
        probe.injector = inj
        // Key codes of "=" and "-" in the current keyboard layout.
        if case .keys(let c) = inj.resolve(.keys(KeyCombo.parse("cmd+=")!)) { probe.zoomIn = c }
        if case .keys(let c) = inj.resolve(.keys(KeyCombo.parse("cmd+-")!)) { probe.zoomOut = c }
    }
    let natural = (CFPreferencesCopyAppValue("com.apple.swipescrolldirection" as CFString,
                                             kCFPreferencesAnyApplication) as? Bool) ?? true
    let mask = CGEventMask(1) << CGEventType.scrollWheel.rawValue
    guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                      options: .listenOnly, eventsOfInterest: mask,
                                      callback: probeCallback, userInfo: nil) else {
        print("cannot create the event tap")
        return 1
    }
    probe.tap = tap
    guard let src = CFMachPortCreateRunLoopSource(nil, tap, 0) else { print("cannot schedule the event tap"); return 1 }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    print("scroll-probe: \(Int(seconds)) s, listen-only, annotated session tap; natural scrolling \(natural ? "on" : "off")"
          + (probe.tryZoom ? "; --try-zoom: ⌘ + scroll over Aperçu sends \(probe.zoomInShift ? "⌘⇧=" : "⌘=") / ⌘-" : ""))
    print("columns: to = target process, from = source process, tag = MTPK (MagicTrackpoint) / MLOG (MagicLogi),")
    print("         cont = continuous, phase = scroll/momentum, lines/pts/fixed = vertical/horizontal deltas,")
    print("         evflags = modifiers in the event, state = modifiers actually held")
    probe.start = Date()
    CFRunLoopRunInMode(.defaultMode, seconds, false)
    CGEvent.tapEnable(tap: tap, enable: false)
    print("scroll-probe: done, \(probe.count) scroll events")
    return 0
}
