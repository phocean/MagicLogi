// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// Modifier + left-button drag = move the document (a "hand" tool), for
// applications that have none (Aperçu's image view only offers selection
// tools). Pure logic: the event tap lives in magiclogid/DragPan.swift.

import Foundation

public struct PanConfig: Equatable, Sendable {
    /// Off unless [pan] enabled = true: no event tap at all otherwise.
    public var enabled = false
    /// The one modifier that must be held, alone, when the button goes down
    /// (option, command or shift; control + click is a right click).
    public var modifier: KeyModifiers = .option
    /// Bundle identifiers of the applications concerned.
    public var apps: [String] = ["com.apple.Preview"]
    public init() {}
}

/// Follows one left-button press at a time. A press that starts with the
/// modifier over a listed application is taken whole (down, drags, up):
/// the application never sees it, and each drag becomes a scroll of the
/// same distance, so the document follows the pointer. Any other press is
/// left entirely alone, even if the modifier is pressed during the drag.
public struct PanTracker: Sendable {
    public enum Input: Equatable, Sendable {
        case down
        /// Pointer movement, in points (x right, y down), as in kCGMouseEventDeltaX/Y.
        case dragged(dx: Double, dy: Double)
        case up
    }

    public enum Decision: Equatable, Sendable {
        /// Not ours: the event goes on unchanged.
        case pass
        /// Absorbed, nothing to send (press, release, zero movement).
        case absorb
        /// Absorbed; scroll by these pixel deltas (wheel 1 = vertical, wheel 2
        /// = horizontal; positive moves the content down / right).
        case scroll(vertical: Double, horizontal: Double)
    }

    public private(set) var active = false

    public init() {}

    public mutating func reset() { active = false }

    /// - Parameters:
    ///   - held: modifiers held for this event (command, option, control, shift only).
    ///   - isTarget: whether the press goes to an application of the list;
    ///     called only for a press with the right modifier.
    public mutating func handle(_ input: Input, held: KeyModifiers, isTarget: () -> Bool,
                                config: PanConfig) -> Decision {
        switch input {
        case .down:
            // A new press always starts afresh (a release we never saw, a
            // tap disabled for a while: nothing stays stuck).
            active = config.enabled && held == config.modifier && isTarget()
            return active ? .absorb : .pass
        case .dragged(let dx, let dy):
            guard active else { return .pass }
            // Grab: the content moves with the hand, both axes.
            guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return .absorb }
            return .scroll(vertical: dy, horizontal: dx)
        case .up:
            guard active else { return .pass }
            active = false
            return .absorb
        }
    }
}
