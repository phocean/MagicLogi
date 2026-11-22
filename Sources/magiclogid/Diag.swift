// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// `magiclogid diag` and `magiclogid events`: read-only investigation tools.
// diag never changes a setting. events only listens (and, with --divert,
// temporarily diverts controls; restored on exit and by the mouse itself on
// power cycle).

import Foundation
import IOKit
import IOKit.hid
import ApplicationServices
import MagicLogiCore

let logitechVendorID = 0x046D

/// Synchronously enumerates the HID devices matching `matching` (no callbacks).
func enumerateDevices(_ matching: [String: Any]) -> (IOHIDManager, [IOHIDDevice]) {
    let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    IOHIDManagerSetDeviceMatching(mgr, matching as CFDictionary)
    let set = IOHIDManagerCopyDevices(mgr) as? Set<IOHIDDevice> ?? []
    return (mgr, Array(set).sorted { hidInt($0, kIOHIDProductIDKey) < hidInt($1, kIOHIDProductIDKey) })
}

func describeUsagePairs(_ device: IOHIDDevice) -> String {
    guard let pairs = hidProperty(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] else { return "?" }
    return pairs.map { p in
        let page = (p[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue ?? 0
        let usage = (p[kIOHIDDeviceUsageKey] as? NSNumber)?.intValue ?? 0
        return String(format: "%04X:%04X", page, usage)
    }.joined(separator: " ")
}

func hasHIDPPCollection(_ device: IOHIDDevice) -> Bool {
    guard let pairs = hidProperty(device, kIOHIDDeviceUsagePairsKey) as? [[String: Any]] else { return false }
    return pairs.contains { p in
        let page = (p[kIOHIDDeviceUsagePageKey] as? NSNumber)?.intValue ?? 0
        return page == 0xFF43 || page == 0xFF00
    }
}

func listenAccessDescription() -> String {
    switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
    case kIOHIDAccessTypeGranted: return "granted"
    case kIOHIDAccessTypeDenied: return "denied"
    default: return "unknown (never asked)"
    }
}

func runDiag(args: [String]) -> Int32 {
    print("magiclogid \(magiclogiVersion) — HID++ diagnostic (read-only)")
    print("Input Monitoring (ListenEvent) for this process: \(listenAccessDescription())")
    if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
        // Registers the program in System Settings > Privacy > Input Monitoring
        // (and prompts the first time). Nothing is opened before the user agrees.
        print("  requesting it: \(IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) ? "granted" : "not granted yet")")
    }
    print("Accessibility (post events): \(CGPreflightPostEventAccess() ? "granted" : "not granted")")
    print("")

    let (mgr, devices) = enumerateDevices([kIOHIDVendorIDKey: logitechVendorID])
    _ = mgr
    if devices.isEmpty {
        print("No Logitech HID device is visible. Is the mouse on and connected in Bluetooth settings?")
        return 1
    }
    for d in devices {
        print(String(format: "Device %@  VID 0x%04X  PID 0x%04X  transport %@",
                     (hidProperty(d, kIOHIDProductKey) as? String) ?? "?",
                     hidInt(d, kIOHIDVendorIDKey), hidInt(d, kIOHIDProductIDKey),
                     (hidProperty(d, kIOHIDTransportKey) as? String) ?? "?"))
        print("  usages: \(describeUsagePairs(d))")
        print("  report sizes: in \(hidInt(d, kIOHIDMaxInputReportSizeKey)) out \(hidInt(d, kIOHIDMaxOutputReportSizeKey)) feature \(hidInt(d, kIOHIDMaxFeatureReportSizeKey))")
        print("  firmware version number: \(hidInt(d, kIOHIDVersionNumberKey))  location 0x\(String(hidInt(d, kIOHIDLocationIDKey), radix: 16))")
        guard hasHIDPPCollection(d) else { print("  no HID++ collection: skipped\n"); continue }
        let dev = LogiDevice(d, softwareID: HIDPP.toolSoftwareID)
        do {
            try dev.open()
            IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            defer {
                dev.close()
                IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
            }
            print("  open: OK (not seized)")
            try probe(dev)
        } catch {
            print("  ERROR: \(error)")
        }
        print("")
    }
    return 0
}

private func line(_ s: String) { print("  " + s) }

private func attempt(_ label: String, _ body: () throws -> Void) {
    do { try body() } catch { line("\(label): \(error)") }
}

func probe(_ dev: LogiDevice) throws {
    let t0 = Date()
    let (maj, minor) = try dev.protocolVersion()
    line("HID++ protocol \(maj).\(minor)  (round trip \(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
    var rtts: [Int] = []
    for _ in 0..<5 {  // identical requests in a row: identical responses must all arrive
        let t = Date()
        _ = try dev.protocolVersion()
        rtts.append(Int(Date().timeIntervalSince(t) * 1000))
    }
    line("5 identical pings: round trips \(rtts.map(String.init).joined(separator: ", ")) ms")
    guard maj >= 2 else { line("HID++ 1.0 device: not supported by this tool"); return }

    // Feature table.
    var present: [UInt16: (index: Int, version: Int)] = [:]
    attempt("FEATURE_SET") {
        let count = Int(try dev.call(.featureSet, 0)[0])
        line("Features (\(count) + ROOT):")
        for i in 1...max(count, 1) where count > 0 {
            let p = try dev.call(.featureSet, 1, [UInt8(i)])
            guard let id = p.u16(0) else { continue }
            let type = p[2], ver = Int(p[3])
            present[id] = (i, ver)
            var flags: [String] = []
            if type & 0x80 != 0 { flags.append("obsolete") }
            if type & 0x40 != 0 { flags.append("hidden") }
            if type & 0x20 != 0 { flags.append("engineering") }
            line(String(format: "  [%2d] 0x%04X v%d %@%@", i, id, ver, Feature.name(of: id),
                        flags.isEmpty ? "" : " (" + flags.joined(separator: ",") + ")"))
        }
    }

    if present[Feature.deviceName.rawValue] != nil {
        attempt("DEVICE_NAME") {
            let len = Int(try dev.call(.deviceName, 0)[0])
            var bytes: [UInt8] = []
            while bytes.count < len && bytes.count < 64 {
                let chunk = try dev.call(.deviceName, 1, [UInt8(bytes.count)])
                bytes += chunk.prefix(len - bytes.count)
            }
            line("Name: \(asciiString(bytes))")
        }
    }
    if present[Feature.firmwareInfo.rawValue] != nil {
        attempt("DEVICE_FW_VERSION") {
            let n = Int(try dev.call(.firmwareInfo, 0)[0])
            for i in 0..<min(n, 8) {
                let p = try dev.call(.firmwareInfo, 1, [UInt8(i)])
                let kinds = ["firmware", "bootloader", "hardware"]
                let kind = Int(p[0] & 0x0F) < kinds.count ? kinds[Int(p[0] & 0x0F)] : "other"
                line(String(format: "Firmware entity %d: %@ %@%02X.%02X build %04X", i, kind,
                            asciiString(Array(p[1...3])), p[4], p[5], Int(p.u16(6) ?? 0)))
            }
        }
    }
    if present[Feature.batteryStatus.rawValue] != nil {
        attempt("BATTERY_STATUS") {
            let p = try dev.call(.batteryStatus, 0)
            if let b = BatteryStatus(params: p) {
                line("Battery: \(b.level)% (next \(b.nextLevel)%), \(b.statusName)")
            } else { line("Battery: unparsable \(p.hex)") }
        }
    }
    if present[Feature.unifiedBattery.rawValue] != nil {
        attempt("UNIFIED_BATTERY") { line("Unified battery status: \(Array(try dev.call(.unifiedBattery, 1).prefix(6)).hex)") }
    }
    if present[Feature.adjustableDPI.rawValue] != nil {
        attempt("ADJUSTABLE_DPI") {
            let sensors = Int(try dev.call(.adjustableDPI, 0)[0])
            line("DPI sensors: \(sensors)")
            let listRaw = try dev.call(.adjustableDPI, 1, [0])
            let list = DPIList.decode(Array(listRaw[1...]))
            line("DPI list raw: \(listRaw.hex)")
            if let first = list.first, let last = list.last {
                line("DPI selectable: \(list.count) values, \(first)…\(last)")
            }
            let cur = try dev.call(.adjustableDPI, 2, [0])
            line("DPI current: \(Int(cur.u16(1) ?? 0)) default: \(Int(cur.u16(3) ?? 0))")
        }
    }
    if present[Feature.reprogControlsV4.rawValue] != nil {
        attempt("REPROG_CONTROLS_V4") {
            let n = Int(try dev.call(.reprogControlsV4, 0)[0])
            line("Controls (\(n)):")
            for i in 0..<min(n, 32) {
                let p = try dev.call(.reprogControlsV4, 1, [UInt8(i)])
                guard let c = ControlInfo(params: p) else { line("  [\(i)] unparsable \(p.hex)"); continue }
                var rep = ""
                if let r = try? dev.call(.reprogControlsV4, 2, [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF)]),
                   let cr = ControlReporting(params: r) {
                    rep = String(format: " reporting flags=0x%02X remap=0x%04X", cr.flags, cr.remap)
                }
                line(String(format: "  [%d] CID 0x%04X %@  TID 0x%04X  group %d mask 0x%02X  [%@]%@",
                            i, c.cid, ControlID.name(c.cid), c.tid, c.group, c.groupMask,
                            c.flagNames.joined(separator: ","), rep))
            }
        }
    }
    if present[Feature.hiResWheel.rawValue] != nil {
        attempt("HIRES_WHEEL") {
            let cap = try dev.call(.hiResWheel, 0)
            line(String(format: "Hi-res wheel: multiplier %d, capability flags 0x%02X", cap[0], cap[1]))
            let m = WheelMode(raw: try dev.call(.hiResWheel, 1)[0])
            line("Wheel mode: diverted=\(m.divertedToHIDPP) hires=\(m.highResolution) inverted=\(m.inverted) (raw 0x\(String(m.raw, radix: 16)))")
            if let r = try? dev.call(.hiResWheel, 3) { line("Ratchet switch state: \(r[0])") }
        }
    }
    if present[Feature.verticalScrolling.rawValue] != nil {
        attempt("VERTICAL_SCROLLING") { line("Vertical scrolling roller info: \(Array(try dev.call(.verticalScrolling, 0).prefix(4)).hex)") }
    }
    if present[Feature.smartShift.rawValue] != nil {
        attempt("SMART_SHIFT") { line("SmartShift mode: \(Array(try dev.call(.smartShift, 0).prefix(4)).hex)") }
    }
    if present[Feature.changeHost.rawValue] != nil {
        attempt("CHANGE_HOST") {
            let p = try dev.call(.changeHost, 0)
            line("Hosts: \(p[0]) channels, current \(Int(p[1]) + 1)")
        }
    }
    let notProbed = present.keys.filter { Feature(rawValue: $0) == nil }.sorted()
    if !notProbed.isEmpty {
        line("Not probed (unknown to this tool): " + notProbed.map { String(format: "0x%04X", $0) }.joined(separator: " "))
    }
}

// MARK: - events

func describeReport(_ r: [UInt8]) -> String {
    guard let id = r.first else { return "empty" }
    switch id {
    case 0x02 where r.count >= 8:
        let buttons = Int(r[1]) | Int(r[2]) << 8
        let raw = Int(r[3]) | Int(r[4]) << 8 | Int(r[5]) << 16
        var x = raw & 0xFFF, y = (raw >> 12) & 0xFFF
        if x >= 0x800 { x -= 0x1000 }
        if y >= 0x800 { y -= 0x1000 }
        let wheel = Int(Int8(bitPattern: r[6])), pan = Int(Int8(bitPattern: r[7]))
        let pressed = (0..<16).filter { buttons & (1 << $0) != 0 }.map { "\($0 + 1)" }
        return "mouse buttons[\(pressed.joined(separator: ","))] x=\(x) y=\(y) wheel=\(wheel) pan=\(pan)"
    case 0x01:
        return "keyboard report from the mouse: \(Array(r.dropFirst()).hex)"
    default:
        return "report 0x\(String(id, radix: 16)): \(r.hex)"
    }
}

func runEvents(args: [String]) -> Int32 {
    var seconds: TimeInterval = 30
    var divert = false
    var motion = false
    for a in args {
        if a == "--divert" { divert = true } else if a == "--motion" { motion = true }
        else if let s = TimeInterval(a), s > 0, s <= 600 { seconds = s }
    }
    let (mgr, devices) = enumerateDevices([kIOHIDVendorIDKey: logitechVendorID])
    _ = mgr
    guard let d = devices.first(where: hasHIDPPCollection) else { print("No Logitech HID++ device"); return 1 }
    let dev = LogiDevice(d, softwareID: HIDPP.toolSoftwareID)
    do { try dev.open() } catch { print("open: \(error)"); return 1 }
    IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
    var diverted: [(cid: UInt16, original: ControlReporting)] = []
    var reprogIndex: UInt8 = 0
    var wheelIndex: UInt8 = 0
    if divert {
        do {
            reprogIndex = try dev.featureIndex(.reprogControlsV4) ?? 0
            wheelIndex = try dev.featureIndex(.hiResWheel) ?? 0
            let n = Int(try dev.call(.reprogControlsV4, 0)[0])
            for i in 0..<n {
                if let c = ControlInfo(params: try dev.call(.reprogControlsV4, 1, [UInt8(i)])),
                   c.isDivertable, c.cid != 0x0050, c.cid != 0x0051,
                   let orig = ControlReporting(params: try dev.call(.reprogControlsV4, 2, [UInt8(c.cid >> 8), UInt8(c.cid & 0xFF)])) {
                    // Remember the state first: restored exactly at the end.
                    diverted.append((c.cid, orig))
                    _ = try dev.call(.reprogControlsV4, 3, ControlReporting.setDivertParams(cid: c.cid, divert: true))
                }
            }
            print("Temporarily diverted: " + diverted.map { ControlID.name($0.cid) }.joined(separator: ", "))
        } catch { print("divert: \(error)") }
    }
    dev.onNotification = { m in
        if m.featureIndex == reprogIndex && reprogIndex != 0 && m.function == 0 {
            let held = decodeDivertedButtons(m.params).map { ControlID.name($0) }
            print("HID++ diverted buttons: [\(held.joined(separator: ", "))]")
        } else if m.featureIndex == wheelIndex && wheelIndex != 0 {
            print("HID++ wheel fn\(m.function): \(Array(m.params.prefix(6)).hex)")
        } else {
            print("HID++ notification feature[\(m.featureIndex)] fn\(m.function) sw\(m.softwareID): \(m.params.hex)")
        }
    }
    dev.onOtherReport = { r in
        if !motion, r.first == 0x02, r.count >= 8, r[1] == 0, r[2] == 0, r[6] == 0, r[7] == 0 { return }
        print(describeReport(r))
    }
    print("Listening \(Int(seconds)) s: press buttons, tilt and roll the wheel (motion-only reports hidden\(motion ? ": no, shown" : ", --motion shows them"))…")
    // Ctrl-C or launchctl bootout must still restore the controls (a
    // diversion outlives the process).
    var interrupted = false
    var sources: [DispatchSourceSignal] = []
    for sig in [SIGINT, SIGTERM, SIGHUP] {
        signal(sig, SIG_IGN)
        let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        src.setEventHandler { interrupted = true }
        src.resume()
        sources.append(src)
    }
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !dev.gone && !interrupted {
        _ = CFRunLoopRunInMode(.defaultMode, 0.25, false)
    }
    var failed = 0
    for (cid, orig) in diverted {
        let p = ControlReporting.setDivertParams(cid: cid, divert: orig.diverted, rawXY: orig.rawXY)
        if (try? dev.call(.reprogControlsV4, 3, p)) == nil { failed += 1 }
    }
    if !diverted.isEmpty {
        print(failed == 0 ? "Original button state restored." : "WARNING: \(failed) control(s) not restored: switch the mouse off and on.")
    }
    dev.close()
    return 0
}

// MARK: - reset (gives the mouse its factory behaviour back)

/// Undiverts every control, clears the wheel mode (no inversion, no hi-res,
/// not diverted) and restores the default DPI. Use it if the agent was
/// removed while a button was diverted, or to undo every setting.
func runReset() -> Int32 {
    let (mgr, devices) = enumerateDevices([kIOHIDVendorIDKey: logitechVendorID, kIOHIDProductIDKey: 0xB01A])
    _ = mgr
    guard let d = devices.first else { print("MX Anywhere 2S not connected"); return 1 }
    let dev = LogiDevice(d, softwareID: HIDPP.toolSoftwareID)
    do {
        try dev.open()
        IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        defer { dev.close() }
        _ = try dev.protocolVersion(timeout: 3)
        for cid in managedControlIDs {
            _ = try? dev.call(.reprogControlsV4, 3, ControlReporting.setDivertParams(cid: cid, divert: false))
        }
        print("Buttons: native")
        _ = try dev.call(.hiResWheel, 2, [0])
        print("Wheel: not inverted, standard resolution")
        let cur = try dev.call(.adjustableDPI, 2, [0])
        if let def = cur.u16(3), def != 0 {
            _ = try dev.call(.adjustableDPI, 3, [0, UInt8(def >> 8), UInt8(def & 0xFF)])
            print("DPI: \(def) (default)")
        }
        return 0
    } catch {
        print("reset: \(error)")
        return 1
    }
}
