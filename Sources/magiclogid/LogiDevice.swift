// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// One opened Logitech HID++ device: synchronous HID++ requests over output
// report 0x11, dispatch of input reports. Main thread / main run loop only.

import Foundation
import IOKit
import IOKit.hid
import MagicLogiCore

enum DeviceError: Error, CustomStringConvertible {
    case openFailed(IOReturn)
    case writeFailed(IOReturn)
    case timeout
    case hidpp(UInt8)
    case gone
    case featureMissing(UInt16)
    case badResponse

    var description: String {
        switch self {
        case .openFailed(let r):
            return r == kIOReturnNotPermitted
                ? "open refused (kIOReturnNotPermitted): Input Monitoring not granted"
                : String(format: "open failed (IOReturn 0x%08X)", UInt32(bitPattern: r))
        case .writeFailed(let r): return String(format: "write failed (IOReturn 0x%08X)", UInt32(bitPattern: r))
        case .timeout: return "no HID++ response (timeout)"
        case .hidpp(let c): return "HID++ error \(HIDPPErrorCode.describe(c))"
        case .gone: return "device disconnected"
        case .featureMissing(let f): return "feature \(Feature.name(of: f)) not present"
        case .badResponse: return "malformed HID++ response"
        }
    }
}

func hidProperty(_ device: IOHIDDevice, _ key: String) -> Any? {
    IOHIDDeviceGetProperty(device, key as CFString)
}

func hidInt(_ device: IOHIDDevice, _ key: String) -> Int {
    (hidProperty(device, key) as? NSNumber)?.intValue ?? 0
}

final class LogiDevice {
    let device: IOHIDDevice
    let productID: Int
    let name: String
    private(set) var isOpen = false
    private(set) var gone = false

    /// HID++ notifications (software ID 0) and unsolicited reports.
    var onNotification: ((HIDPPMessage) -> Void)?
    /// Every other input report (report ID first). Only installed by `events`.
    var onOtherReport: (([UInt8]) -> Void)?

    private var featureIndexCache: [UInt16: UInt8] = [:]
    private var pendingRequest: HIDPPMessage?
    private var pendingResponse: HIDPPMessage?
    private let reportBuffer: UnsafeMutablePointer<UInt8>
    private let reportBufferSize = 64

    let softwareID: UInt8

    init(_ device: IOHIDDevice, softwareID: UInt8 = HIDPP.softwareID) {
        self.device = device
        self.softwareID = softwareID
        productID = hidInt(device, kIOHIDProductIDKey)
        name = (hidProperty(device, kIOHIDProductKey) as? String) ?? "?"
        reportBuffer = .allocate(capacity: reportBufferSize)
        reportBuffer.initialize(repeating: 0, count: reportBufferSize)
    }

    deinit {
        close()
        reportBuffer.deallocate()
    }

    /// Opens without seizing: macOS keeps receiving the mouse normally.
    /// Opens without seizing: macOS keeps receiving the mouse normally.
    /// Every input report of the device reaches the callback (macOS offers no
    /// reliable per-report filter: an element-value callback on page 0xFF43
    /// was tried and drops identical consecutive HID++ responses). Non-HID++
    /// reports are discarded at the first byte unless `onOtherReport` is set.
    func open() throws {
        guard !isOpen else { return }
        let r = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard r == kIOReturnSuccess else { throw DeviceError.openFailed(r) }
        isOpen = true
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, reportBufferSize, { ctx, result, _, _, reportID, report, length in
            guard let ctx, result == kIOReturnSuccess, length > 0 else { return }
            let me = Unmanaged<LogiDevice>.fromOpaque(ctx).takeUnretainedValue()
            // Fast path: mouse/keyboard reports are dropped without being copied.
            if reportID != UInt32(HIDPP.longReportID) && me.onOtherReport == nil { return }
            var bytes = Array(UnsafeBufferPointer(start: report, count: length))
            // Normalise: always report ID first.
            if bytes.first != UInt8(truncatingIfNeeded: reportID) || length == HIDPP.longReportLength - 1 {
                bytes.insert(UInt8(truncatingIfNeeded: reportID), at: 0)
            }
            me.handleReport(bytes)
        }, ctx)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        // Unregister before closing so no callback can reach a freed object.
        IOHIDDeviceRegisterInputReportCallback(device, reportBuffer, reportBufferSize, nil, nil)
        if !gone { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
    }

    func markGone() {
        gone = true
        pendingRequest = nil
    }

    private func handleReport(_ bytes: [UInt8]) {
        if bytes.first == HIDPP.longReportID, let msg = HIDPPMessage(report: bytes) {
            if let req = pendingRequest, msg.answers(req) {
                pendingResponse = msg
                return
            }
            onNotification?(msg)
            return
        }
        onOtherReport?(bytes)
    }

    // MARK: Requests

    /// Sends one request and waits for its response, servicing the run loop.
    func send(featureIndex: UInt8, function: UInt8, params: [UInt8] = [],
              timeout: TimeInterval = 1.0) throws -> HIDPPMessage {
        guard isOpen, !gone else { throw DeviceError.gone }
        guard pendingRequest == nil else { throw DeviceError.badResponse } // no re-entrancy
        let req = HIDPPMessage(featureIndex: featureIndex, function: function, softwareID: softwareID, params: params)
        pendingRequest = req
        pendingResponse = nil
        defer { pendingRequest = nil; pendingResponse = nil }
        let out = req.bytes
        let r = out.withUnsafeBufferPointer {
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(HIDPP.longReportID), $0.baseAddress!, out.count)
        }
        guard r == kIOReturnSuccess else { throw DeviceError.writeFailed(r) }
        let deadline = Date().addingTimeInterval(timeout)
        while pendingResponse == nil {
            if gone { throw DeviceError.gone }
            let left = deadline.timeIntervalSinceNow
            if left <= 0 { throw DeviceError.timeout }
            _ = CFRunLoopRunInMode(.defaultMode, min(left, 0.05), true)
        }
        guard let resp = pendingResponse else { throw DeviceError.timeout }
        if let code = resp.errorCode { throw DeviceError.hidpp(code) }
        return resp
    }

    /// Feature index of `feature`, via ROOT.getFeature (cached). nil if absent.
    func featureIndex(_ feature: Feature) throws -> UInt8? {
        if feature == .root { return 0 }
        if let i = featureIndexCache[feature.rawValue] { return i == 0 ? nil : i }
        let id = feature.rawValue
        let resp = try send(featureIndex: 0, function: 0, params: [UInt8(id >> 8), UInt8(id & 0xFF)])
        featureIndexCache[id] = resp.params[0]
        return resp.params[0] == 0 ? nil : resp.params[0]
    }

    /// Calls `function` of `feature`; throws featureMissing if absent.
    func call(_ feature: Feature, _ function: UInt8, _ params: [UInt8] = [],
              timeout: TimeInterval = 1.0) throws -> [UInt8] {
        guard let idx = try featureIndex(feature) else { throw DeviceError.featureMissing(feature.rawValue) }
        return try send(featureIndex: idx, function: function, params: params, timeout: timeout).params
    }

    /// ROOT.getProtocolVersion: (major, minor). Also a liveness ping.
    func protocolVersion(timeout: TimeInterval = 1.0) throws -> (Int, Int) {
        let ping: UInt8 = 0x5A
        let p = try send(featureIndex: 0, function: 1, params: [0, 0, ping], timeout: timeout).params
        return (Int(p[0]), Int(p[1]))
    }

    /// Index of `feature` if already resolved, without any I/O (safe inside
    /// report callbacks). 0 = unknown or absent.
    func cachedIndex(_ feature: Feature) -> UInt8 { featureIndexCache[feature.rawValue] ?? 0 }

    func resetFeatureCache() { featureIndexCache.removeAll() }
}
