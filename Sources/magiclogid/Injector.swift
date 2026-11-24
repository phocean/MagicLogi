// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// Synthesizes the configured action of a diverted button with CGEventPost
// (Accessibility permission). Down on press, up on release, so holding and
// dragging behave like a real button or key.

import ApplicationServices
import Carbon.HIToolbox
import MagicLogiCore

final class Injector {
    /// Written in kCGEventSourceUserData of every event we post ("MLOG").
    static let marker: Int64 = 0x4D4C_4F47
    private let source = CGEventSource(stateID: .hidSystemState)

    /// CGPreflightPostEventAccess() keeps the answer it gave at the first
    /// call for the life of the process (verified: a grant made while the
    /// agent runs is not seen). AXIsProcessTrusted() is read live, and the
    /// Accessibility grant is what allows posting events.
    static var allowed: Bool { AXIsProcessTrusted() || CGPreflightPostEventAccess() }

    // Modifier keys in the order a person presses them.
    private static let modifierKeys: [(KeyModifiers, CGKeyCode, CGEventFlags)] = [
        (.control, CGKeyCode(kVK_Control), .maskControl),
        (.option, CGKeyCode(kVK_Option), .maskAlternate),
        (.shift, CGKeyCode(kVK_Shift), .maskShift),
        (.command, CGKeyCode(kVK_Command), .maskCommand),
        (.function, CGKeyCode(kVK_Function), .maskSecondaryFn),
    ]

    func post(_ action: ButtonAction, down: Bool) {
        switch action {
        case .native, .none, .gestures:
            return
        case .mouseButton(let n):
            let location = CGEvent(source: nil)?.location ?? .zero
            let type: CGEventType
            switch n {
            case 0: type = down ? .leftMouseDown : .leftMouseUp
            case 1: type = down ? .rightMouseDown : .rightMouseUp
            default: type = down ? .otherMouseDown : .otherMouseUp
            }
            guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                                  mouseButton: CGMouseButton(rawValue: UInt32(n)) ?? .center) else { return }
            e.setIntegerValueField(.mouseEventButtonNumber, value: Int64(n))
            send(e)
        case .keys(let combo):
            postKeys(combo, down: down)
        case .system(let shortcut):
            let entry = Injector.symbolicHotKeys()?[String(shortcut.id)] as? [String: Any]
            switch shortcut.resolve(entry: entry) {
            case .combo(let combo): postKeys(combo, down: down)
            case .disabled:
                if down { log.error("system shortcut \(shortcut.id) is disabled in System Settings > Keyboard > Keyboard Shortcuts: nothing sent") }
            }
        }
    }

    /// The concrete action to post for a press, fixed at press time: the
    /// release then sends exactly the same keys even if the keyboard layout
    /// or the system shortcut changes while the button is held.
    func resolve(_ action: ButtonAction) -> ButtonAction {
        switch action {
        case .keys(let combo) where combo.character != nil:
            return .keys(KeyCombo(keyCode: resolvedKeyCode(combo), modifiers: combo.modifiers))
        case .system(let shortcut):
            let entry = Injector.symbolicHotKeys()?[String(shortcut.id)] as? [String: Any]
            switch shortcut.resolve(entry: entry) {
            case .combo(let combo): return .keys(combo)
            case .disabled:
                log.error("system shortcut \(shortcut.id) is disabled in System Settings > Keyboard > Keyboard Shortcuts: nothing sent")
                return .none
            }
        default:
            return action
        }
    }

    /// Press and release at once (gesture results).
    func tap(_ action: ButtonAction) {
        let a = resolve(action)
        post(a, down: true)
        post(a, down: false)
    }

    /// The user's system shortcuts, re-read at each press (cheap; follows
    /// changes made in System Settings without a restart).
    static func symbolicHotKeys() -> [String: Any]? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain) as? [String: Any]
    }

    /// Like a keyboard: modifiers down, key down … key up, modifiers up. The
    /// Dock only triggers system shortcuts (⌃↑ Mission Control…) when the
    /// modifier keys themselves have been pressed, not just flagged.
    private func postKeys(_ combo: KeyCombo, down: Bool) {
        let mods = Injector.modifierKeys.filter { combo.modifiers.contains($0.0) }
        let keyCode = resolvedKeyCode(combo)
        var allFlags: CGEventFlags = mods.reduce([]) { $0.union($1.2) }
        if combo.isFunctionKey { allFlags.insert(.maskSecondaryFn) }
        if combo.isArrow { allFlags.insert(.maskNumericPad) }
        let modFlags: CGEventFlags = mods.reduce([]) { $0.union($1.2) }

        if down {
            var flags: CGEventFlags = []
            for (_, code, flag) in mods {
                flags.insert(flag)
                key(code, down: true, flags: flags)
            }
            key(keyCode, down: true, flags: allFlags)
        } else {
            key(keyCode, down: false, flags: allFlags)
            var flags = modFlags
            for (_, code, flag) in mods.reversed() {
                flags.remove(flag)
                key(code, down: false, flags: flags)
            }
        }
    }

    /// One press of `combo` delivered to a single process (CGEventPostToPid),
    /// with its modifiers as flags only: no modifier key events, so the
    /// modifier the user is physically holding is left alone. Used by the
    /// zoom, whose target is the application under the pointer, not
    /// necessarily the active one.
    func pressKeys(_ combo: KeyCombo, toPid pid: pid_t) {
        let code = resolvedKeyCode(combo)
        var flags: CGEventFlags = Injector.modifierKeys
            .filter { combo.modifiers.contains($0.0) }.reduce([]) { $0.union($1.2) }
        if combo.isFunctionKey { flags.insert(.maskSecondaryFn) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: Injector.marker)
            e.postToPid(pid)
        }
    }

    private func key(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { return }
        e.flags = flags
        send(e)
    }

    private func send(_ e: CGEvent) {
        log.debug("posting event type \(e.type.rawValue) key \(e.getIntegerValueField(.keyboardEventKeycode)) flags 0x\(String(e.flags.rawValue, radix: 16), privacy: .public)")
        e.setIntegerValueField(.eventSourceUserData, value: Injector.marker)
        e.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard layout

    private var layoutCache: (id: String, map: [Character: CGKeyCode])?

    /// Key code that types `combo.character` in the active keyboard layout
    /// (unshifted), else the ANSI position.
    private func resolvedKeyCode(_ combo: KeyCombo) -> CGKeyCode {
        guard let ch = combo.character else { return combo.keyCode }
        return layoutMap()[ch] ?? combo.keyCode
    }

    private func layoutMap() -> [Character: CGKeyCode] {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return [:] }
        let id: String = {
            guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceID) else { return "?" }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }()
        if let c = layoutCache, c.id == id { return c.map }
        var map: [Character: CGKeyCode] = [:]
        if let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data
            data.withUnsafeBytes { raw in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
                for code in 0..<128 {
                    var dead: UInt32 = 0
                    var len = 0
                    var chars = [UniChar](repeating: 0, count: 4)
                    let r = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                           OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                    guard r == noErr, len == 1,
                          let ch = String(utf16CodeUnits: chars, count: 1).lowercased().first,
                          map[ch] == nil else { continue }
                    map[ch] = CGKeyCode(code)
                }
            }
        }
        layoutCache = (id, map)
        log.info("keyboard layout \(id, privacy: .public): \(map.count) keys mapped")
        return map
    }
}
