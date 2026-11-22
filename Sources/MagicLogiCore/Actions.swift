// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// What a button does. "native" = untouched (the mouse's own HID button,
// no HID++ diversion). Everything else needs the control to be diverted and
// the action synthesized by the daemon.

import Foundation

public struct KeyModifiers: OptionSet, Hashable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let shift = KeyModifiers(rawValue: 2)
    public static let option = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
    public static let function = KeyModifiers(rawValue: 16)
}

/// A keyboard shortcut: a key plus modifiers.
///
/// Printable keys (letters, digits, punctuation) are stored as the CHARACTER
/// the user wrote: the daemon finds, in the active keyboard layout, the key
/// that types it (on AZERTY "a" is not the ANSI "a" position, and posting the
/// ANSI code for "cmd+a" would send ⌘Q). `keyCode` is the ANSI position, used
/// only if no key of the layout types the character. Other keys (arrows,
/// F-keys, return…) have no layout dependency.
public struct KeyCombo: Equatable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: KeyModifiers
    public var character: Character?
    /// Arrow, F-keys, navigation keys: posted with the "secondary fn" (and,
    /// for arrows, numeric pad) flags, as a real keyboard does; the Dock only
    /// recognises ⌃↑ & co. when these flags are present.
    public var isFunctionKey: Bool { KeyCombo.functionKeyCodes.contains(keyCode) }
    public var isArrow: Bool { (0x7B...0x7E).contains(keyCode) }

    public init(keyCode: UInt16, modifiers: KeyModifiers, character: Character? = nil) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.character = character
    }

    static let functionKeyCodes: Set<UInt16> = [
        0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F, // F1-F12
        0x7B, 0x7C, 0x7D, 0x7E,                                                 // arrows
        0x73, 0x77, 0x74, 0x79, 0x75,                                           // home end pgup pgdn fwd-delete
    ]

    /// ANSI-layout key codes (kVK_ANSI_*), i.e. physical positions.
    static let keyNames: [String: UInt16] = {
        var m: [String: UInt16] = [
            "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
            "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
            "t": 0x11, "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
            "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E, "o": 0x1F, "u": 0x20,
            "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29,
            "\\": 0x2A, ",": 0x2B, "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
            "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33,
            "backspace": 0x33, "escape": 0x35, "esc": 0x35, "forwarddelete": 0x75,
            "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
            "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        ]
        let f: [UInt16] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for (i, code) in f.enumerated() { m["f\(i + 1)"] = code }
        return m
    }()

    /// Parses "cmd+shift+4", "ctrl+up", "f11"… (case-insensitive).
    public static func parse(_ text: String) -> KeyCombo? {
        let parts = text.lowercased().split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let keyName = parts.last, !keyName.isEmpty else { return nil }
        var mods: KeyModifiers = []
        for p in parts.dropLast() {
            switch p {
            case "cmd", "command": mods.insert(.command)
            case "shift": mods.insert(.shift)
            case "opt", "option", "alt": mods.insert(.option)
            case "ctrl", "control": mods.insert(.control)
            case "fn": mods.insert(.function)
            default: return nil
            }
        }
        guard let code = keyNames[keyName] else { return nil }
        let printable = keyName.count == 1 ? keyName.first : nil
        return KeyCombo(keyCode: code, modifiers: mods, character: printable)
    }
}

/// A macOS system shortcut (System Settings > Keyboard > Keyboard
/// Shortcuts), identified by its index in com.apple.symbolichotkeys. The
/// daemon reads the user's current shortcut at each press; `fallback` is the
/// macOS default, used when the preference holds no entry.
public struct SystemShortcut: Equatable, Hashable, Sendable {
    public var id: Int
    public var fallback: KeyCombo

    public static let missionControl = SystemShortcut(id: 32, fallback: KeyCombo(keyCode: 0x7E, modifiers: .control))
    public static let applicationWindows = SystemShortcut(id: 33, fallback: KeyCombo(keyCode: 0x7D, modifiers: .control))
    public static let showDesktop = SystemShortcut(id: 36, fallback: KeyCombo(keyCode: 0x67, modifiers: []))
    public static let spotlight = SystemShortcut(id: 64, fallback: KeyCombo(keyCode: 0x31, modifiers: .command))
    public static let spaceLeft = SystemShortcut(id: 79, fallback: KeyCombo(keyCode: 0x7B, modifiers: .control))
    public static let spaceRight = SystemShortcut(id: 81, fallback: KeyCombo(keyCode: 0x7C, modifiers: .control))

    public enum Resolution: Equatable, Sendable {
        case combo(KeyCombo)
        case disabled
    }

    /// Decodes one AppleSymbolicHotKeys entry: {enabled, value = {parameters
    /// = (character, keyCode, modifierFlags)}}. Modifier flags use the
    /// CGEventFlags bits (shift 0x20000, control 0x40000, option 0x80000,
    /// command 0x100000; numeric pad 0x200000 and fn 0x800000 are implied by
    /// the key). nil entry → fallback.
    public func resolve(entry: [String: Any]?) -> Resolution {
        guard let entry else { return .combo(fallback) }
        if let enabled = entry["enabled"] as? Bool, !enabled { return .disabled }
        if let enabled = entry["enabled"] as? Int, enabled == 0 { return .disabled }
        guard let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count >= 3,
              (0..<128).contains(params[1]) else { return .combo(fallback) }
        let f = params[2]
        var mods: KeyModifiers = []
        if f & 0x20000 != 0 { mods.insert(.shift) }
        if f & 0x40000 != 0 { mods.insert(.control) }
        if f & 0x80000 != 0 { mods.insert(.option) }
        if f & 0x100000 != 0 { mods.insert(.command) }
        return .combo(KeyCombo(keyCode: UInt16(params[1]), modifiers: mods))
    }
}

public enum ButtonAction: Equatable, Hashable, Sendable {
    case native
    case none
    case mouseButton(Int)       // 0-based CG button number: 2 = middle, 3 = back, 4 = forward
    case keys(KeyCombo)
    case system(SystemShortcut)
    /// Hold the button and move the mouse: see Config.gestures.
    case gestures

    /// Named actions.
    public static let named: [String: ButtonAction] = [
        "native": .native,
        "none": .none,
        "gestures": .gestures,
        "middle-click": .mouseButton(2),
        "button4": .mouseButton(3),
        "button5": .mouseButton(4),
        // Back/forward = mouse buttons 4/5, which macOS 27 apps (Safari,
        // Finder, browsers) handle natively: no keyboard-layout dependency,
        // unlike ⌘[ / ⌘] (verified: ⌘[ posted as ANSI keys does nothing on
        // an AZERTY layout).
        "back": .mouseButton(3),
        "forward": .mouseButton(4),
        // The user's own shortcut for these is read from the system
        // preferences at each press (verified: shortcuts can be customised,
        // e.g. Mission Control on ⇧⌘↑ instead of ⌃↑).
        "mission-control": .system(.missionControl),
        "app-expose": .system(.applicationWindows),
        "space-left": .system(.spaceLeft),
        "space-right": .system(.spaceRight),
        "show-desktop": .system(.showDesktop),
        "spotlight": .system(.spotlight),
    ]

    public static func parse(_ text: String) -> ButtonAction? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.lowercased().hasPrefix("keys:") {
            return KeyCombo.parse(String(t.dropFirst(5))).map { .keys($0) }
        }
        return named[t.lowercased()]
    }

    /// True if the control must be diverted (HID++) for this action.
    public var needsDiversion: Bool { self != .native }
    /// True if the daemon must post events (Accessibility permission).
    public var needsEventPosting: Bool {
        switch self {
        case .native, .none: return false
        case .mouseButton, .keys, .system, .gestures: return true
        }
    }
}
