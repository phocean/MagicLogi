// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste

/// Logitech software that talks to the mouse itself and so competes with
/// the agent for it.
///
/// Verified with Logi Plugin Service (2026-11-23), a component the Logi
/// Options+ installer puts in /Applications/Utilities and that stays after
/// Options+ is removed: it starts at login and connects to the mouse over
/// Bluetooth each time the display turns on. From then on the mouse sends
/// the diverted buttons' events to it, not to the agent: the buttons go
/// silent (no action, no native click) although they still read as diverted.
/// The other entries talk HID++ to the same mice; not tested here.
///
/// Only these fixed paths are checked (a file-existence test each): no
/// process list is read, nothing else on the disk is looked at.
public struct ConflictingSoftware: Equatable, Sendable {
    public let name: String
    public let path: String
}

public enum Conflicts {
    public static let known: [ConflictingSoftware] = [
        ConflictingSoftware(name: "Logi Plugin Service", path: "/Applications/Utilities/LogiPluginService.app"),
        ConflictingSoftware(name: "Logi Options+", path: "/Applications/logioptionsplus.app"),
        ConflictingSoftware(name: "Logi Options", path: "/Applications/Logi Options.app"),
        ConflictingSoftware(name: "Logitech G HUB", path: "/Applications/lghub.app"),
    ]

    /// The known software present, in `known` order.
    public static func installed(exists: (String) -> Bool) -> [ConflictingSoftware] {
        known.filter { exists($0.path) }
    }

    /// One-line explanation for the log and the command line.
    public static func warning(_ found: [ConflictingSoftware]) -> String? {
        guard !found.isEmpty else { return nil }
        let names = found.map(\.name).joined(separator: ", ")
        let paths = found.map(\.path).joined(separator: ", ")
        return "Logitech software installed (\(names)): it talks to the mouse and can take the remapped buttons over, which then stop responding (verified with Logi Plugin Service). Uninstall it (\(paths))."
    }
}
