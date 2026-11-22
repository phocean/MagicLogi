// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// The resident agent. One thread, one run loop, no polling:
//   IOHIDManager (046D:B01A only) → open (not seized) → apply the config
//   HID++ notifications → diverted buttons, reconnection (0x1D4B), battery
//   IORegisterForSystemPower → re-apply after wake
//   SIGHUP → reload the config, SIGTERM/SIGINT → undo diversions and exit

import Foundation
import IOKit
import IOKit.hid
import IOKit.pwr_mgt
import ApplicationServices
import MagicLogiCore
import os

let log = Logger(subsystem: "com.jcbaptiste.magiclogi", category: "agent")

let mxAnywhere2SProductID = 0xB01A

// IOKit power messages (function-like C macros, not imported by Swift).
private let msgCanSystemSleep: UInt32 = 0xE000_0270
private let msgSystemWillSleep: UInt32 = 0xE000_0280
private let msgSystemHasPoweredOn: UInt32 = 0xE000_0300

final class Agent {
    private let configPath: String
    private var config = Config()
    private let manager: IOHIDManager
    private let injector = Injector()

    private var device: LogiDevice?
    /// Matched but not opened yet (missing Input Monitoring permission).
    private var waitingDevice: IOHIDDevice?
    private var discovered = false
    private var presentControls: Set<UInt16> = []
    private var dpiList: [Int] = []
    private var diverted: Set<UInt16> = []
    private var tracker = DivertedButtonTracker()
    private var heldActions: [UInt16: ButtonAction] = [:]
    private var gesture = GestureTracker(threshold: 130)
    private var gestureCID: UInt16?
    private var battery: BatteryStatus?
    private var currentDPI: Int?

    private var applying = false
    private var applyPending = false
    private var applyFailures = 0
    private var applyWork: DispatchWorkItem?
    private var stopping = false
    private var permissionTimer: Timer?
    private var askedAccessibility = false

    private var signalSources: [DispatchSourceSignal] = []
    private var powerConnection: io_connect_t = 0
    private var powerNotifier: io_object_t = 0
    private var powerPort: IONotificationPortRef?

    init(configPath: String) {
        self.configPath = configPath
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    // MARK: Startup

    func run() -> Never {
        let shownPath = configPath.hasPrefix(NSHomeDirectory()) ? "~" + configPath.dropFirst(NSHomeDirectory().count) : configPath
        log.notice("magiclogid \(magiclogiVersion, privacy: .public) starting, config \(shownPath, privacy: .public)")
        loadConfig(initial: true)
        log.notice("permissions: input monitoring \(IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted ? "yes" : "no", privacy: .public), accessibility \(AXIsProcessTrusted() ? "yes" : "no", privacy: .public), post events \(CGPreflightPostEventAccess() ? "yes" : "no", privacy: .public)")
        installSignalHandlers()
        registerForPower()

        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            log.error("Input Monitoring not granted: System Settings > Privacy & Security > Input Monitoring > magiclogid")
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }

        let matching: [String: Any] = [kIOHIDVendorIDKey: logitechVendorID, kIOHIDProductIDKey: mxAnywhere2SProductID]
        IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<Agent>.fromOpaque(ctx).takeUnretainedValue().deviceMatched(dev)
        }, ctx)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { ctx, _, _, dev in
            guard let ctx else { return }
            Unmanaged<Agent>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(dev)
        }, ctx)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        writeStatus()
        CFRunLoopRun()
        exit(0)
    }

    private func loadConfig(initial: Bool) {
        let text: String
        do {
            text = try String(contentsOfFile: configPath, encoding: .utf8)
        } catch {
            if FileManager.default.fileExists(atPath: configPath) {
                log.error("cannot read the configuration file: \(error.localizedDescription, privacy: .public)")
            } else {
                log.notice("no configuration file: the mouse is left unchanged")
            }
            if initial { config = Config() }
            return
        }
        do {
            config = try Config.parse(text)
            log.notice("configuration: \(self.config.summary, privacy: .public)")
        } catch {
            // At startup: run with nothing changed. On reload: keep the
            // previous, valid configuration.
            log.error("invalid configuration (\(String(describing: error), privacy: .public)): \(initial ? "mouse left unchanged" : "previous configuration kept", privacy: .public)")
            if initial { config = Config() }
        }
    }

    // MARK: Device lifecycle

    private func deviceMatched(_ hid: IOHIDDevice) {
        if let d = device, CFEqual(d.device, hid) { return }
        if device != nil { log.notice("another MX Anywhere 2S appeared: ignored (one mouse at a time)"); return }
        let transport = (hidProperty(hid, kIOHIDTransportKey) as? String) ?? "?"
        log.notice("MX Anywhere 2S connected (\(transport, privacy: .public))")
        openDevice(hid)
    }

    private func openDevice(_ hid: IOHIDDevice) {
        let dev = LogiDevice(hid)
        do {
            try dev.open()
        } catch DeviceError.openFailed(let r) where r == kIOReturnNotPermitted {
            log.error("cannot open the mouse: Input Monitoring not granted to magiclogid; waiting for it")
            waitingDevice = hid
            startPermissionTimer()
            return
        } catch {
            log.error("cannot open the mouse: \(String(describing: error), privacy: .public)")
            return
        }
        waitingDevice = nil
        device = dev
        discovered = false
        diverted = []
        applyFailures = 0
        dev.onNotification = { [weak self] msg in self?.handleNotification(msg) }
        scheduleApply(after: 0.3)
    }

    private func deviceRemoved(_ hid: IOHIDDevice) {
        if let w = waitingDevice, CFEqual(w, hid) { waitingDevice = nil }
        guard let d = device, CFEqual(d.device, hid) else { return }
        log.notice("MX Anywhere 2S disconnected")
        releaseHeld()
        d.markGone()
        d.close()
        device = nil
        diverted = []
        writeStatus()
    }

    // MARK: Applying the configuration (idempotent)

    private func scheduleApply(after delay: TimeInterval) {
        applyWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.apply() }
        applyWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func apply() {
        guard let dev = device, !stopping else { return }
        if applying { applyPending = true; return }
        applying = true
        defer {
            applying = false
            if stopping { finishStop() }
            if applyPending { applyPending = false; scheduleApply(after: 0.1) }
        }
        releaseHeld()
        do {
            // The first request also wakes the mouse's radio: generous timeout.
            _ = try dev.protocolVersion(timeout: 3)
            if !discovered { try discover(dev) }
            try applyDPI(dev)
            try applyWheel(dev)
            try applyButtons(dev)
            readBattery(dev)
            applyFailures = 0
            writeStatus()
        } catch DeviceError.gone {
            return
        } catch {
            applyFailures += 1
            if applyFailures <= 3 {
                let delay = Double(1 << applyFailures)
                log.error("applying settings failed (\(String(describing: error), privacy: .public)); retry in \(Int(delay)) s")
                scheduleApply(after: delay)
            } else {
                log.error("applying settings failed (\(String(describing: error), privacy: .public)); giving up until the next reconnection or wake")
            }
        }
    }

    private func discover(_ dev: LogiDevice) throws {
        // Resolve now the indices that notifications are matched against.
        for f in [Feature.reprogControlsV4, .wirelessDeviceStatus, .batteryStatus, .hiResWheel, .adjustableDPI] {
            _ = try dev.featureIndex(f)
        }
        presentControls = []
        if try dev.featureIndex(.reprogControlsV4) != nil {
            let n = Int(try dev.call(.reprogControlsV4, 0)[0])
            for i in 0..<min(n, 32) {
                if let c = ControlInfo(params: try dev.call(.reprogControlsV4, 1, [UInt8(i)])), c.isDivertable {
                    presentControls.insert(c.cid)
                }
            }
        }
        dpiList = []
        if try dev.featureIndex(.adjustableDPI) != nil {
            let raw = try dev.call(.adjustableDPI, 1, [0])
            dpiList = DPIList.decode(Array(raw[1...]))
        }
        discovered = true
        log.info("discovered \(self.presentControls.count) divertable controls, \(self.dpiList.count) DPI values")
    }

    private func applyDPI(_ dev: LogiDevice) throws {
        guard dev.isOpen, try dev.featureIndex(.adjustableDPI) != nil else { return }
        let cur = try dev.call(.adjustableDPI, 2, [0])
        currentDPI = cur.u16(1).map(Int.init)
        guard let wanted = config.dpi else { return }
        guard let target = DPIList.nearest(wanted, in: dpiList) else { return }
        if target != wanted { log.notice("dpi \(wanted) not supported, using \(target)") }
        if currentDPI != target {
            let r = try dev.call(.adjustableDPI, 3, [0, UInt8(target >> 8), UInt8(target & 0xFF)])
            currentDPI = r.u16(1).map(Int.init)
            log.notice("dpi set to \(self.currentDPI ?? 0)")
        }
    }

    private func applyWheel(_ dev: LogiDevice) throws {
        guard try dev.featureIndex(.hiResWheel) != nil else { return }
        let mode = WheelMode(raw: try dev.call(.hiResWheel, 1)[0])
        // We never divert the wheel nor use hi-res mode (macOS would scroll 8x
        // faster): clear both, set the invert bit as configured.
        let want = WheelMode(diverted: false, highResolution: false,
                             inverted: config.invertScroll ?? mode.inverted)
        if want != mode {
            // setWheelMode rewrites the whole byte: read-modify-write above.
            _ = try dev.call(.hiResWheel, 2, [want.raw])
            log.notice("wheel mode set: inverted=\(want.inverted)")
        }
    }

    private func applyButtons(_ dev: LogiDevice) throws {
        guard try dev.featureIndex(.reprogControlsV4) != nil else { return }
        let canPost = Injector.allowed
        var blocked: [String] = []
        for cid in managedControlIDs where presentControls.contains(cid) {
            let action = Control(cid: cid).map { config.action(for: $0) } ?? .native
            var want = action.needsDiversion
            let wantRaw = action == .gestures
            if want && action.needsEventPosting && !canPost {
                // Never leave a button diverted with nobody able to act on it.
                want = false
                blocked.append(Control(cid: cid)?.rawValue ?? "?")
            }
            let r = try dev.call(.reprogControlsV4, 2, [UInt8(cid >> 8), UInt8(cid & 0xFF)])
            guard let rep = ControlReporting(params: r), rep.cid == cid else { throw DeviceError.badResponse }
            if rep.diverted != want || rep.rawXY != (want && wantRaw) {
                _ = try dev.call(.reprogControlsV4, 3, ControlReporting.setDivertParams(cid: cid, divert: want, rawXY: wantRaw))
                log.notice("\(ControlID.name(cid), privacy: .public): \(want ? (wantRaw ? "diverted with motion (gestures)" : "diverted") : "native", privacy: .public)")
            }
            if want { diverted.insert(cid) } else { diverted.remove(cid) }
        }
        if !blocked.isEmpty {
            log.error("Accessibility not granted: \(blocked.joined(separator: ","), privacy: .public) left native until it is (System Settings > Privacy & Security > Accessibility > magiclogid)")
            if !askedAccessibility { askedAccessibility = true; _ = CGRequestPostEventAccess() }
            startPermissionTimer()
        }
    }

    private func readBattery(_ dev: LogiDevice) {
        guard let p = try? dev.call(.batteryStatus, 0), let b = BatteryStatus(params: p) else { return }
        updateBattery(b)
    }

    private func updateBattery(_ b: BatteryStatus) {
        if b != battery {
            if b.level <= 10 {
                log.warning("battery \(b.level)% (\(b.statusName, privacy: .public))")
            } else {
                log.notice("battery \(b.level)% (\(b.statusName, privacy: .public))")
            }
        }
        battery = b
        writeStatus()
    }

    // MARK: Notifications from the mouse

    private func handleNotification(_ msg: HIDPPMessage) {
        log.debug("HID++ notification feature \(msg.featureIndex) fn \(msg.function) sw \(msg.softwareID)")
        // While stopping, nothing new may be pressed (it could never be released).
        guard let dev = device, msg.softwareID == 0, !stopping else { return }
        let idx = msg.featureIndex
        guard idx != 0 else { return }
        if idx == dev.cachedIndex(.reprogControlsV4) {
            if msg.function == 1 {
                // rawXY: motion while a "gestures" button is held.
                guard gesture.active, let (dx, dy) = decodeRawXY(msg.params) else { return }
                if let d = gesture.add(dx: dx, dy: dy) {
                    let a = config.gestures[GestureSlot(d)] ?? .none
                    log.debug("gesture \(d.rawValue, privacy: .public)")
                    if Injector.allowed { injector.tap(a) }
                }
                return
            }
            guard msg.function == 0 else { return }
            let (pressed, released) = tracker.update(decodeDivertedButtons(msg.params))
            log.debug("diverted buttons: pressed \(pressed.map { String(format: "%04X", $0) }, privacy: .public) released \(released.map { String(format: "%04X", $0) }, privacy: .public)")
            for cid in released {
                if let a = heldActions.removeValue(forKey: cid) { injector.post(a, down: false) }
                if cid == gestureCID {
                    gestureCID = nil
                    if gesture.end(), Injector.allowed {
                        log.debug("gesture click")
                        injector.tap(config.gestures[.click] ?? .none)
                    }
                }
            }
            for cid in pressed where diverted.contains(cid) {
                guard let control = Control(cid: cid) else { continue }
                let a = config.action(for: control)
                guard a.needsEventPosting else { continue }
                guard Injector.allowed else {
                    // Accessibility revoked while running: give the buttons
                    // back to the mouse rather than leave them silent.
                    log.error("Accessibility revoked: remapped buttons back to native")
                    scheduleApply(after: 0)
                    break
                }
                if a == .gestures {
                    gesture.threshold = config.gestureThreshold
                    gesture.begin()
                    gestureCID = cid
                    continue
                }
                let concrete = injector.resolve(a)
                heldActions[cid] = concrete
                injector.post(concrete, down: true)
            }
        } else if idx == dev.cachedIndex(.wirelessDeviceStatus), msg.function == 0 {
            // [status 1 = reconnection, request 1 = reconfiguration needed, reason]
            log.notice("mouse reconnected (status \(msg.params[0]) request \(msg.params[1]) reason \(msg.params[2])): re-applying")
            releaseHeld()
            diverted = []
            scheduleApply(after: 0.2)
        } else if idx == dev.cachedIndex(.batteryStatus), msg.function == 0 {
            if let b = BatteryStatus(params: msg.params) { updateBattery(b) }
        }
    }

    /// Releases whatever we synthesized as "pressed" (disconnection, sleep,
    /// re-application, stop): no key or button may stay stuck down.
    private func releaseHeld() {
        gesture.cancel()
        gestureCID = nil
        for cid in tracker.releaseAll() {
            if let a = heldActions.removeValue(forKey: cid) { injector.post(a, down: false) }
        }
        for (_, a) in heldActions { injector.post(a, down: false) }
        heldActions = [:]
    }

    // MARK: Permissions (only while one is missing)

    private func startPermissionTimer() {
        guard permissionTimer == nil else { return }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.checkPermissions()
        }
    }

    private func checkPermissions() {
        var stillWaiting = false
        if let hid = waitingDevice {
            if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted {
                log.notice("Input Monitoring granted")
                openDevice(hid)
            }
            stillWaiting = waitingDevice != nil
        }
        if device != nil && config.needsEventPosting {
            if Injector.allowed {
                if Control.allCases.contains(where: { config.action(for: $0).needsEventPosting && !diverted.contains($0.cid) }) {
                    log.notice("Accessibility granted")
                    scheduleApply(after: 0)
                }
            } else {
                stillWaiting = true
            }
        }
        if !stillWaiting {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    // MARK: Sleep / wake

    private func registerForPower() {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        powerConnection = IORegisterForSystemPower(ctx, &powerPort, { ctx, _, messageType, argument in
            guard let ctx else { return }
            Unmanaged<Agent>.fromOpaque(ctx).takeUnretainedValue().power(messageType, argument)
        }, &powerNotifier)
        guard powerConnection != 0, let port = powerPort else {
            log.error("cannot register for sleep/wake notifications")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
    }

    private func power(_ type: UInt32, _ argument: UnsafeMutableRawPointer?) {
        switch type {
        case msgCanSystemSleep:
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case msgSystemWillSleep:
            releaseHeld()
            IOAllowPowerChange(powerConnection, Int(bitPattern: argument))
        case msgSystemHasPoweredOn:
            if device != nil {
                log.info("system woke: re-applying")
                applyFailures = 0
                scheduleApply(after: 2)
            }
        default:
            break
        }
    }

    // MARK: Signals and stop

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                guard let self else { return }
                if sig == SIGHUP {
                    log.notice("SIGHUP: reloading configuration")
                    self.loadConfig(initial: false)
                    self.applyFailures = 0
                    self.scheduleApply(after: 0)
                } else {
                    self.stop()
                }
            }
            src.resume()
            signalSources.append(src)
        }
    }

    private func stop() {
        guard !stopping else { return }
        stopping = true
        log.notice("stopping")
        applyWork?.cancel()
        if !applying { finishStop() }
        // else: apply() calls finishStop() when its current request returns.
    }

    /// Gives the mouse back its native behaviour: diversions do NOT end when
    /// the process exits (verified), so they must be undone here.
    private func finishStop() -> Never {
        releaseHeld()
        if let dev = device, !dev.gone {
            // Every managed control, not only those we believe diverted: the
            // set is empty just after a reconnection, while the mouse may
            // still hold a diversion (security review F2).
            let controls = discovered ? managedControlIDs.filter(presentControls.contains) : managedControlIDs
            var failed: [String] = []
            for cid in controls {
                let p = ControlReporting.setDivertParams(cid: cid, divert: false)
                if (try? dev.call(.reprogControlsV4, 3, p, timeout: 1)) == nil { failed.append(ControlID.name(cid)) }
            }
            if failed.isEmpty {
                log.notice("all buttons back to native")
            } else {
                log.error("could not restore \(failed.joined(separator: ", "), privacy: .public): switch the mouse off and on")
            }
            dev.close()
        }
        device = nil
        diverted = []
        releaseHeld()   // anything queued while the requests above ran
        writeStatus(stopped: true)
        exit(0)
    }

    // MARK: Status file (read by `magiclogid status`)

    private func writeStatus(stopped: Bool = false) {
        var lines = ["updated=\(ISO8601DateFormatter().string(from: Date()))"]
        lines.append("version=\(magiclogiVersion)")
        lines.append("agent=\(stopped ? "stopped" : "running")")
        let im = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        lines.append("input_monitoring=\(im ? "granted" : "missing")")
        lines.append("accessibility=\(!config.needsEventPosting ? "not-needed" : Injector.allowed ? "granted" : "missing")")
        lines.append("connected=\(device != nil ? "yes" : "no")")
        if waitingDevice != nil { lines.append("waiting=input-monitoring") }
        if let b = battery { lines.append("battery=\(b.level)%"); lines.append("battery_status=\(b.statusName)") }
        if let d = currentDPI { lines.append("dpi=\(d)") }
        let names = diverted.sorted().compactMap { Control(cid: $0)?.rawValue }
        lines.append("diverted=\(names.isEmpty ? "none" : names.joined(separator: ","))")
        StatusFile.write(lines.joined(separator: "\n") + "\n")
    }
}

enum StatusFile {
    static var path: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".local/state/magiclogi/status")
    }

    static func write(_ text: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
