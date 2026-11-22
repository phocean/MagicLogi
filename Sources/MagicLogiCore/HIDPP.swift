// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import Foundation
//
// HID++ 2.0 framing. Only the long report (ID 0x11, 20 bytes) exists on the
// MX Anywhere 2S over Bluetooth LE (see docs/etude-faisabilite.md).

public enum HIDPP {
    public static let longReportID: UInt8 = 0x11
    public static let longReportLength = 20
    public static let paramLength = 16
    /// Device index of a device connected directly (Bluetooth), not via a receiver.
    public static let directDeviceIndex: UInt8 = 0xFF
    /// Feature index used by the device for HID++ 2.0 error responses.
    public static let errorFeatureIndex: UInt8 = 0xFF
    /// Our software ID (low nibble of byte 3). Non-zero so that our responses
    /// are distinguishable from notifications, which carry software ID 0.
    /// 0x0C: not used by Solaar (0x0B), OpenRGB (0x07), G HUB (0x0D) or
    /// firmware tools (0x0F), so concurrent tools do not steal our replies.
    public static let softwareID: UInt8 = 0x0C
    /// Software ID of the diag/events/reset subcommands, distinct from the
    /// agent's so that a diagnostic run while the agent works can never
    /// answer the agent's requests (security review F3).
    public static let toolSoftwareID: UInt8 = 0x0E
}

/// HID++ 2.0 feature IDs used by this project.
public enum Feature: UInt16, CaseIterable, Sendable {
    case root = 0x0000
    case featureSet = 0x0001
    case firmwareInfo = 0x0003
    case deviceName = 0x0005
    case batteryStatus = 0x1000
    case batteryVoltage = 0x1001
    case unifiedBattery = 0x1004
    case changeHost = 0x1814
    case hostsInfo = 0x1815
    case reprogControlsV4 = 0x1B04
    case persistentRemappableAction = 0x1C00
    case wirelessDeviceStatus = 0x1D4B
    case verticalScrolling = 0x2100
    case smartShift = 0x2110
    case hiResScrolling = 0x2120
    case hiResWheel = 0x2121
    case thumbWheel = 0x2150
    case adjustableDPI = 0x2201
    case onboardProfiles = 0x8100

    public var name: String {
        switch self {
        case .root: return "ROOT"
        case .featureSet: return "FEATURE_SET"
        case .firmwareInfo: return "DEVICE_FW_VERSION"
        case .deviceName: return "DEVICE_NAME"
        case .batteryStatus: return "BATTERY_STATUS"
        case .batteryVoltage: return "BATTERY_VOLTAGE"
        case .unifiedBattery: return "UNIFIED_BATTERY"
        case .changeHost: return "CHANGE_HOST"
        case .hostsInfo: return "HOSTS_INFO"
        case .reprogControlsV4: return "REPROG_CONTROLS_V4"
        case .persistentRemappableAction: return "PERSISTENT_REMAPPABLE_ACTION"
        case .wirelessDeviceStatus: return "WIRELESS_DEVICE_STATUS"
        case .verticalScrolling: return "VERTICAL_SCROLLING"
        case .smartShift: return "SMART_SHIFT"
        case .hiResScrolling: return "HI_RES_SCROLLING"
        case .hiResWheel: return "HIRES_WHEEL"
        case .thumbWheel: return "THUMB_WHEEL"
        case .adjustableDPI: return "ADJUSTABLE_DPI"
        case .onboardProfiles: return "ONBOARD_PROFILES"
        }
    }

    public static func name(of id: UInt16) -> String {
        Feature(rawValue: id)?.name ?? String(format: "UNKNOWN_%04X", id)
    }
}

/// One HID++ long message (request, response or notification).
public struct HIDPPMessage: Equatable, Sendable {
    public var deviceIndex: UInt8
    public var featureIndex: UInt8
    public var function: UInt8      // 0...15
    public var softwareID: UInt8    // 0...15
    public var params: [UInt8]      // exactly 16 bytes

    public init(deviceIndex: UInt8 = HIDPP.directDeviceIndex, featureIndex: UInt8,
                function: UInt8, softwareID: UInt8 = HIDPP.softwareID, params: [UInt8] = []) {
        self.deviceIndex = deviceIndex
        self.featureIndex = featureIndex
        self.function = function & 0x0F
        self.softwareID = softwareID & 0x0F
        var p = Array(params.prefix(HIDPP.paramLength))
        p += [UInt8](repeating: 0, count: HIDPP.paramLength - p.count)
        self.params = p
    }

    /// 20-byte output report, report ID included.
    public var bytes: [UInt8] {
        [HIDPP.longReportID, deviceIndex, featureIndex, (function << 4) | softwareID] + params
    }

    /// Parses a received report (report ID included). Returns nil for anything
    /// that is not a well-formed HID++ long report: the device is untrusted input.
    public init?(report: [UInt8]) {
        guard report.count == HIDPP.longReportLength, report[0] == HIDPP.longReportID else { return nil }
        self.deviceIndex = report[1]
        self.featureIndex = report[2]
        self.function = report[3] >> 4
        self.softwareID = report[3] & 0x0F
        self.params = Array(report[4..<20])
    }

    public var isError: Bool { featureIndex == HIDPP.errorFeatureIndex }

    // Error layout: [0x11, dev, 0xFF, reqFeatureIndex, reqFnSw, code, ...].
    // After parsing: featureIndex = 0xFF, function/softwareID come from byte 3
    // which here is the *request feature index*, params[0] = request fn|sw,
    // params[1] = error code.
    private var report3Feature: UInt8 { (function << 4) | softwareID }

    /// True if `self` answers `request` (same feature, function and software ID),
    /// either as a normal response or as an error response.
    public func answers(_ request: HIDPPMessage) -> Bool {
        if isError {
            return report3Feature == request.featureIndex
                && params[0] == ((request.function << 4) | request.softwareID)
        }
        return featureIndex == request.featureIndex
            && function == request.function
            && softwareID == request.softwareID
    }

    /// HID++ 2.0 error code if this is an error response.
    public var errorCode: UInt8? { isError ? params[1] : nil }
}

public enum HIDPPErrorCode {
    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 0x00: return "NoError"
        case 0x01: return "Unknown"
        case 0x02: return "InvalidArgument"
        case 0x03: return "OutOfRange"
        case 0x04: return "HardwareError"
        case 0x05: return "LogitechInternal"
        case 0x06: return "InvalidFeatureIndex"
        case 0x07: return "InvalidFunctionID"
        case 0x08: return "Busy"
        case 0x09: return "Unsupported"
        default: return String(format: "0x%02X", code)
        }
    }
}

extension Array where Element == UInt8 {
    public var hex: String { map { String(format: "%02X", $0) }.joined(separator: " ") }

    public func u16(_ at: Int) -> UInt16? {
        guard at >= 0, at + 1 < count else { return nil }
        return UInt16(self[at]) << 8 | UInt16(self[at + 1])
    }
}
