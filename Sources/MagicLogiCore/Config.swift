// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

import Foundation

/// The reprogrammable controls of the MX Anywhere 2S (verified on the device,
/// docs/etude-faisabilite.md §4). Left/right buttons are not reprogrammable.
public enum Control: String, CaseIterable, Sendable {
    case middle            // dedicated button behind the wheel, HID button 3
    case back              // rear side button, HID button 4
    case forward           // front side button, HID button 5
    case tiltLeft = "tilt_left"
    case tiltRight = "tilt_right"

    public var cid: UInt16 {
        switch self {
        case .middle: return 0x0052
        case .back: return 0x0053
        case .forward: return 0x0056
        case .tiltLeft: return 0x005B
        case .tiltRight: return 0x005D
        }
    }

    public init?(cid: UInt16) {
        guard let c = Control.allCases.first(where: { $0.cid == cid }) else { return nil }
        self = c
    }
}

/// Controls the daemon owns: every one is forced to its configured state on
/// each (re)connection, which also clears a diversion left by a crash. The
/// virtual gesture button (0x00D7) is never diverted by us but is reset too.
public let managedControlIDs: [UInt16] = Control.allCases.map(\.cid) + [0x00D7]

public struct Config: Equatable, Sendable {
    /// Hardware DPI; nil = leave the mouse's value alone.
    public var dpi: Int?
    /// Hardware wheel inversion (HIRES_WHEEL invert bit); nil = leave alone.
    public var invertScroll: Bool?
    public var buttons: [Control: ButtonAction]
    /// What a "gestures" button does: click, or hold and move.
    public var gestures: [GestureSlot: ButtonAction] = GestureSlot.defaults
    public var gestureThreshold = 130
    /// Modifier + scroll = zoom ([zoom]); off unless enabled.
    public var zoom = ZoomConfig()
    /// Modifier + left-button drag = move the document ([pan]); off unless enabled.
    public var pan = PanConfig()

    public static let dpiRange = 200...4000
    public static let gestureThresholdRange = 20...5000

    public init(dpi: Int? = nil, invertScroll: Bool? = nil, buttons: [Control: ButtonAction] = [:]) {
        self.dpi = dpi; self.invertScroll = invertScroll; self.buttons = buttons
    }

    public func action(for control: Control) -> ButtonAction { buttons[control] ?? .native }

    /// True if a button, the zoom or the pan needs the Accessibility permission.
    public var needsEventPosting: Bool {
        zoom.enabled || pan.enabled || Control.allCases.contains { action(for: $0).needsEventPosting }
    }

    public static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".config/magiclogi/config.toml")
    }

    /// Strict: unknown tables, keys or values are errors (a typo must not be
    /// silently ignored).
    public static func parse(_ text: String) throws -> Config {
        let doc = try TOMLDocument.parse(text)
        var cfg = Config()
        let known: [String: Set<String>] = [
            "": [],
            "pointer": ["dpi"],
            "scroll": ["invert"],
            "buttons": Set(Control.allCases.map(\.rawValue)),
            "gestures": Set(GestureSlot.allCases.map(\.rawValue) + ["threshold"]),
            "zoom": ["enabled", "modifier", "step", "invert", "apps"],
            "pan": ["enabled", "modifier", "apps"],
        ]
        for (table, keys) in doc.tables {
            guard let allowed = known[table] else {
                throw TOMLError(line: doc.tableLines[table] ?? 0, message: "unknown table [\(table)]")
            }
            for (key, entry) in keys where !allowed.contains(key) {
                let where_ = table.isEmpty ? "at top level" : "in [\(table)]"
                throw TOMLError(line: entry.line, message: "unknown key \"\(key)\" \(where_)")
            }
        }
        if let e = doc.tables["pointer"]?["dpi"] {
            guard case .integer(let v) = e.value else {
                throw TOMLError(line: e.line, message: "dpi must be an integer, got \(e.value.typeName)")
            }
            guard dpiRange.contains(v) else {
                throw TOMLError(line: e.line, message: "dpi \(v) out of range \(dpiRange.lowerBound)…\(dpiRange.upperBound)")
            }
            cfg.dpi = v
        }
        if let e = doc.tables["scroll"]?["invert"] {
            guard case .boolean(let v) = e.value else {
                throw TOMLError(line: e.line, message: "invert must be true or false, got \(e.value.typeName)")
            }
            cfg.invertScroll = v
        }
        for (key, e) in doc.tables["buttons"] ?? [:] {
            guard let control = Control(rawValue: key) else { continue }
            guard case .string(let s) = e.value else {
                throw TOMLError(line: e.line, message: "\(key) must be a string, got \(e.value.typeName)")
            }
            guard let action = ButtonAction.parse(s) else {
                let names = ButtonAction.named.keys.sorted().joined(separator: ", ")
                throw TOMLError(line: e.line, message: "unknown action \"\(s)\" for \(key) (use one of: \(names), or \"keys:cmd+shift+4\")")
            }
            cfg.buttons[control] = action
        }
        for (key, e) in doc.tables["gestures"] ?? [:] {
            if key == "threshold" {
                guard case .integer(let v) = e.value, gestureThresholdRange.contains(v) else {
                    throw TOMLError(line: e.line, message: "threshold must be an integer in \(gestureThresholdRange.lowerBound)…\(gestureThresholdRange.upperBound)")
                }
                cfg.gestureThreshold = v
                continue
            }
            guard let slot = GestureSlot(rawValue: key) else { continue }
            guard case .string(let s) = e.value, let action = ButtonAction.parse(s),
                  action != .native, action != .gestures else {
                throw TOMLError(line: e.line, message: "gesture \(key): expected an action other than \"native\" and \"gestures\" (\"none\" disables it)")
            }
            cfg.gestures[slot] = action
        }
        cfg.zoom = try parseZoom(doc.tables["zoom"] ?? [:])
        cfg.pan = try parsePan(doc.tables["pan"] ?? [:])
        return cfg
    }

    private static func parseZoom(_ t: [String: (value: TOMLValue, line: Int)]) throws -> ZoomConfig {
        var z = ZoomConfig()
        if let e = t["enabled"] {
            guard case .boolean(let v) = e.value else {
                throw TOMLError(line: e.line, message: "enabled must be true or false, got \(e.value.typeName)")
            }
            z.enabled = v
        }
        if let e = t["modifier"] {
            z.modifier = try parseModifier(e, controlRefused: "control + scroll is macOS's own screen zoom (Accessibility)")
        }
        if let e = t["step"] {
            guard case .integer(let v) = e.value, ZoomConfig.stepRange.contains(v) else {
                throw TOMLError(line: e.line, message: "step must be an integer in \(ZoomConfig.stepRange.lowerBound)…\(ZoomConfig.stepRange.upperBound)")
            }
            z.step = v
        }
        if let e = t["invert"] {
            guard case .boolean(let v) = e.value else {
                throw TOMLError(line: e.line, message: "invert must be true or false, got \(e.value.typeName)")
            }
            z.invert = v
        }
        if let e = t["apps"] { z.apps = try parseApps(e) }
        return z
    }

    private static func parsePan(_ t: [String: (value: TOMLValue, line: Int)]) throws -> PanConfig {
        var p = PanConfig()
        if let e = t["enabled"] {
            guard case .boolean(let v) = e.value else {
                throw TOMLError(line: e.line, message: "enabled must be true or false, got \(e.value.typeName)")
            }
            p.enabled = v
        }
        if let e = t["modifier"] {
            p.modifier = try parseModifier(e, controlRefused: "control + click is a right click on macOS")
        }
        if let e = t["apps"] { p.apps = try parseApps(e) }
        return p
    }

    /// One modifier among cmd, alt, shift; control is refused with `controlRefused` as the reason.
    private static func parseModifier(_ e: (value: TOMLValue, line: Int), controlRefused: String) throws -> KeyModifiers {
        guard case .string(let s) = e.value else {
            throw TOMLError(line: e.line, message: "modifier must be a string, got \(e.value.typeName)")
        }
        switch s.lowercased() {
        case "cmd", "command": return .command
        case "opt", "option", "alt": return .option
        case "shift": return .shift
        case "ctrl", "control":
            throw TOMLError(line: e.line, message: "modifier \"\(s)\" is refused: \(controlRefused); use cmd, alt or shift")
        default:
            throw TOMLError(line: e.line, message: "unknown modifier \"\(s)\" (use cmd, alt or shift)")
        }
    }

    /// A non-empty list of bundle identifiers.
    private static func parseApps(_ e: (value: TOMLValue, line: Int)) throws -> [String] {
        guard case .strings(let list) = e.value else {
            throw TOMLError(line: e.line, message: "apps must be a list of bundle identifiers, e.g. [\"com.apple.Preview\"]")
        }
        guard !list.isEmpty else { throw TOMLError(line: e.line, message: "apps is empty (set enabled = false instead)") }
        for id in list where !ZoomConfig.isValidBundleID(id) {
            throw TOMLError(line: e.line, message: "\"\(id)\" is not a bundle identifier (e.g. com.apple.Preview)")
        }
        return list
    }

    private static func modifierName(_ m: KeyModifiers) -> String {
        m == .command ? "cmd" : m == .option ? "alt" : "shift"
    }

    /// One-line human summary for the log.
    public var summary: String {
        var parts: [String] = []
        parts.append("dpi=" + (dpi.map(String.init) ?? "unchanged"))
        parts.append("invert=" + (invertScroll.map { $0 ? "on" : "off" } ?? "unchanged"))
        let remapped = Control.allCases.filter { action(for: $0) != .native }
        parts.append("remapped=" + (remapped.isEmpty ? "none" : remapped.map(\.rawValue).joined(separator: ",")))
        if Control.allCases.contains(where: { action(for: $0) == .gestures }) {
            parts.append("gesture_threshold=\(gestureThreshold)")
        }
        if zoom.enabled {
            parts.append("zoom=\(Config.modifierName(zoom.modifier))+scroll step=\(zoom.step)\(zoom.invert ? " inverted" : "") apps=\(zoom.apps.joined(separator: ","))")
        }
        if pan.enabled {
            parts.append("pan=\(Config.modifierName(pan.modifier))+drag apps=\(pan.apps.joined(separator: ","))")
        }
        return parts.joined(separator: " ")
    }
}

/// The five things a "gestures" button can do. Defaults: click = a normal
/// middle click (the button keeps its native use), up = Mission Control,
/// down = application windows, left/right = previous/next desktop space.
public enum GestureSlot: String, CaseIterable, Sendable {
    case click, left, right, up, down

    public static let defaults: [GestureSlot: ButtonAction] = [
        .click: .mouseButton(2),
        .up: .system(.missionControl),
        .down: .system(.applicationWindows),
        .left: .system(.spaceLeft),
        .right: .system(.spaceRight),
    ]

    public init(_ d: GestureTracker.Direction) {
        switch d {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        }
    }
}

/// Press/release edges from the "currently held" sets sent by the mouse in
/// divertedButtonsEvent notifications.
public struct DivertedButtonTracker: Sendable {
    public private(set) var held: Set<UInt16> = []
    public init() {}

    public mutating func update(_ now: Set<UInt16>) -> (pressed: [UInt16], released: [UInt16]) {
        let pressed = now.subtracting(held).sorted()
        let released = held.subtracting(now).sorted()
        held = now
        return (pressed, released)
    }

    /// Forget everything (disconnection, sleep, stop); returns what was held
    /// so the caller can release what it synthesized.
    public mutating func releaseAll() -> [UInt16] {
        defer { held = [] }
        return held.sorted()
    }
}
