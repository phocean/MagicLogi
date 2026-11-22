// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import Foundation
//
// Parsers for HID++ 2.0 response payloads. Every parser validates its input
// and returns nil (or skips the value) on anything unexpected.

// MARK: - ADJUSTABLE_DPI (0x2201)

public enum DPIList {
    /// Decodes the payload of getSensorDpiList (params after the sensor index
    /// byte, i.e. params[1...]). Values are big-endian 16-bit; 0 ends the list;
    /// a value with the top three bits 0b111 (0xE000 mask) is a step: the
    /// list then describes a range "previous value ... next value, by step".
    /// Returns the sorted set of selectable DPI values.
    public static func decode(_ raw: [UInt8]) -> [Int] {
        var words: [Int] = []
        var i = 0
        while i + 1 < raw.count {
            let w = Int(raw[i]) << 8 | Int(raw[i + 1])
            if w == 0 { break }
            words.append(w)
            i += 2
        }
        var out: [Int] = []
        var k = 0
        while k < words.count {
            let w = words[k]
            if w & 0xE000 == 0xE000 {
                let step = w & 0x1FFF
                guard step > 0, let low = out.last, k + 1 < words.count else { k += 1; continue }
                let high = words[k + 1]
                guard high > low, high & 0xE000 != 0xE000 else { k += 1; continue }
                var v = low + step
                while v <= high && out.count < 2000 { out.append(v); v += step }
                if out.last != high { out.append(high) }
                k += 2
            } else {
                out.append(w)
                k += 1
            }
        }
        return Array(Set(out)).sorted()
    }

    /// The selectable value closest to `wanted` (ties: the lower one).
    public static func nearest(_ wanted: Int, in list: [Int]) -> Int? {
        list.min { a, b in
            let da = abs(a - wanted), db = abs(b - wanted)
            return da != db ? da < db : a < b
        }
    }
}

// MARK: - REPROG_CONTROLS_V4 (0x1B04)

public struct ControlInfo: Equatable, Sendable {
    public var cid: UInt16
    public var tid: UInt16
    public var flags: UInt8          // byte 4
    public var position: UInt8       // byte 5 (F-key position, 0 for mice)
    public var group: UInt8          // byte 6
    public var groupMask: UInt8      // byte 7
    public var additionalFlags: UInt8 // byte 8

    public var isMouseButton: Bool { flags & 0x01 != 0 }
    public var isReprogrammable: Bool { flags & 0x10 != 0 }
    public var isDivertable: Bool { flags & 0x20 != 0 }
    public var isPersistentlyDivertable: Bool { flags & 0x40 != 0 }
    public var isVirtual: Bool { flags & 0x80 != 0 }
    public var supportsRawXY: Bool { additionalFlags & 0x01 != 0 }

    /// Parses getCidInfo params.
    public init?(params p: [UInt8]) {
        guard p.count >= 9, let cid = p.u16(0), let tid = p.u16(2), cid != 0 else { return nil }
        self.cid = cid; self.tid = tid
        flags = p[4]; position = p[5]; group = p[6]; groupMask = p[7]; additionalFlags = p[8]
    }

    public init(cid: UInt16, tid: UInt16, flags: UInt8, position: UInt8 = 0,
                group: UInt8 = 0, groupMask: UInt8 = 0, additionalFlags: UInt8 = 0) {
        self.cid = cid; self.tid = tid; self.flags = flags; self.position = position
        self.group = group; self.groupMask = groupMask; self.additionalFlags = additionalFlags
    }

    public var flagNames: [String] {
        var n: [String] = []
        if isMouseButton { n.append("mouse") }
        if flags & 0x02 != 0 { n.append("fkey") }
        if flags & 0x04 != 0 { n.append("hotkey") }
        if flags & 0x08 != 0 { n.append("fntoggle") }
        if isReprogrammable { n.append("reprog") }
        if isDivertable { n.append("divert") }
        if isPersistentlyDivertable { n.append("persist") }
        if isVirtual { n.append("virtual") }
        if supportsRawXY { n.append("rawXY") }
        if additionalFlags & 0x08 != 0 { n.append("rawWheel") }
        return n
    }
}

/// Control IDs known to appear on Logitech mice (names from Logitech's
/// public HID++ control list as used by Solaar).
public enum ControlID {
    public static func name(_ cid: UInt16) -> String {
        switch cid {
        case 0x0050: return "Left Button"
        case 0x0051: return "Right Button"
        case 0x0052: return "Middle Button"
        case 0x0053: return "Back Button"
        case 0x0056: return "Forward Button"
        case 0x005B: return "Left Tilt"
        case 0x005D: return "Right Tilt"
        case 0x00C3: return "Gesture Button"
        case 0x00C4: return "Smart Shift"
        case 0x00D7: return "Virtual Gesture Button"
        default: return String(format: "CID 0x%04X", cid)
        }
    }
}

public struct ControlReporting: Equatable, Sendable {
    public var cid: UInt16
    public var flags: UInt8   // bit0 divert, bit2 persistent divert, bit4 rawXY
    public var remap: UInt16  // 0 or the CID this control is remapped to

    public var diverted: Bool { flags & 0x01 != 0 }
    public var persistentlyDiverted: Bool { flags & 0x04 != 0 }

    /// Parses getCidReporting params.
    public init?(params p: [UInt8]) {
        guard p.count >= 5, let cid = p.u16(0), let remap = p.u16(3) else { return nil }
        self.cid = cid; flags = p[2]; self.remap = remap
    }

    public var rawXY: Bool { flags & 0x10 != 0 }

    /// Params for setCidReporting setting the temporary divert and raw-XY
    /// bits. Byte 2: bit0 divert (bit1 = apply it), bit4 rawXY (bit5 = apply
    /// it). With rawXY, the mouse's motion is sent as HID++ rawXY events
    /// instead of moving the pointer while the control is held (gestures).
    /// Persistent divert and remap are left untouched (their valid bits are 0).
    public static func setDivertParams(cid: UInt16, divert: Bool, rawXY: Bool = false) -> [UInt8] {
        [UInt8(cid >> 8), UInt8(cid & 0xFF),
         (divert ? 0x01 : 0x00) | 0x02 | (divert && rawXY ? 0x10 : 0x00) | 0x20, 0, 0]
    }
}

/// rawXY event (REPROG_CONTROLS_V4 function 1): dx, dy as big-endian
/// signed 16-bit counts (y grows downwards).
public func decodeRawXY(_ p: [UInt8]) -> (dx: Int, dy: Int)? {
    guard let x = p.u16(0), let y = p.u16(2) else { return nil }
    return (Int(Int16(bitPattern: x)), Int(Int16(bitPattern: y)))
}

/// Gesture recognition while a "gestures" button is held: the first axis
/// whose accumulated motion reaches `threshold` fires; motion then counts
/// from zero again, so gestures chain without releasing the button. Each
/// further gesture of the same hold needs `chainPercent` % of threshold, so one
/// long swipe does not fire a burst (2.25×, tuned on the device: 3× too
/// long, 1.5× fired bursts). A release with no gesture is a click.
public struct GestureTracker: Sendable {
    public enum Direction: String, CaseIterable, Sendable { case left, right, up, down }
    public static let chainPercent = 225
    public var threshold: Int
    public private(set) var active = false
    private var dx = 0, dy = 0, fired = 0

    public init(threshold: Int) { self.threshold = threshold }

    public mutating func begin() { active = true; dx = 0; dy = 0; fired = 0 }

    public mutating func add(dx ddx: Int, dy ddy: Int) -> Direction? {
        guard active else { return nil }
        // Clamp: a hostile or glitching device cannot overflow the sums.
        dx = max(-1_000_000, min(1_000_000, dx + ddx))
        dy = max(-1_000_000, min(1_000_000, dy + ddy))
        let needed = fired == 0 ? threshold : threshold * GestureTracker.chainPercent / 100
        guard max(abs(dx), abs(dy)) >= needed else { return nil }
        let d: Direction = abs(dx) >= abs(dy) ? (dx < 0 ? .left : .right) : (dy < 0 ? .up : .down)
        fired += 1
        dx = 0; dy = 0
        return d
    }

    /// Ends the hold; true if it was a click (no direction fired).
    public mutating func end() -> Bool {
        defer { active = false }
        return active && fired == 0
    }

    public mutating func cancel() { active = false }
}

/// divertedButtonsEvent (REPROG_CONTROLS_V4 function 0): up to four CIDs
/// currently held, big-endian, zero-padded. Empty = all released.
public func decodeDivertedButtons(_ params: [UInt8]) -> Set<UInt16> {
    var s = Set<UInt16>()
    var i = 0
    while i + 1 < min(params.count, 8) {
        if let c = params.u16(i), c != 0 { s.insert(c) }
        i += 2
    }
    return s
}

// MARK: - BATTERY_STATUS (0x1000)

public struct BatteryStatus: Equatable, Sendable {
    public var level: Int        // percent, 0 = unknown
    public var nextLevel: Int
    public var status: UInt8     // 0 discharging, 1 recharging, 2 almost full, 3 full, ...

    public init?(params p: [UInt8]) {
        guard p.count >= 3, p[0] <= 100, p[1] <= 100 else { return nil }
        level = Int(p[0]); nextLevel = Int(p[1]); status = p[2]
    }

    public var statusName: String {
        switch status {
        case 0: return "discharging"
        case 1: return "recharging"
        case 2: return "almost full"
        case 3: return "full"
        case 4: return "slow recharge"
        case 5: return "invalid battery"
        case 6: return "thermal error"
        default: return String(format: "status 0x%02X", status)
        }
    }
}

// MARK: - HIRES_WHEEL (0x2121)

public struct WheelMode: Equatable, Sendable {
    public var raw: UInt8
    public var divertedToHIDPP: Bool { raw & 0x01 != 0 }
    public var highResolution: Bool { raw & 0x02 != 0 }
    public var inverted: Bool { raw & 0x04 != 0 }

    public init(raw: UInt8) { self.raw = raw }

    public init(diverted: Bool, highResolution: Bool, inverted: Bool) {
        raw = (diverted ? 0x01 : 0) | (highResolution ? 0x02 : 0) | (inverted ? 0x04 : 0)
    }
}

// MARK: - Device name / firmware

public func asciiString(_ bytes: [UInt8]) -> String {
    String(decoding: bytes.prefix { $0 != 0 }.map { ($0 >= 0x20 && $0 < 0x7F) ? $0 : 0x3F }, as: UTF8.self)
}
