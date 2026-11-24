// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Jean-Christophe Baptiste
//
// Modifier + scroll = zoom, for applications that lack it (Aperçu). Pure
// logic: the event tap lives in magiclogid/ScrollZoom.swift. Design and
// measurements: docs/etude-zoom.md.

import Foundation

public struct ZoomConfig: Equatable, Sendable {
    /// Off unless [zoom] enabled = true: no event tap at all otherwise.
    public var enabled = false
    /// The one modifier that must be held, alone (command, option or shift).
    public var modifier: KeyModifiers = .command
    /// Scroll distance per zoom step, in points (kCGScrollWheelEventPointDeltaAxis1).
    public var step = 120
    /// true: scrolling up zooms out.
    public var invert = false
    /// Bundle identifiers of the applications concerned.
    public var apps: [String] = ["com.apple.Preview"]

    public static let stepRange = 5...2000
    public init() {}

    /// Syntax of a bundle identifier (reverse DNS: letters, digits, "-", ".").
    public static func isValidBundleID(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return s.count <= 255 && parts.count >= 2 && parts.allSatisfy { p in
            !p.isEmpty && p.unicodeScalars.allSatisfy {
                ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "-"
            }
        }
    }
}

/// Decides, for each scroll event, whether to leave it alone or absorb it
/// and how many zoom steps it is worth. Deltas are accumulated so that a
/// high-resolution wheel or the TrackPoint (many small events) does not fire
/// a burst of zoom commands.
public struct ZoomTracker: Sendable {
    public enum Decision: Equatable, Sendable {
        /// Not ours: the event goes on unchanged.
        case pass
        /// Absorbed; `steps` > 0 zoom in, < 0 zoom out, 0 nothing yet.
        case absorb(steps: Int)
    }

    /// The accumulated distance is forgotten after this pause.
    public static let idleReset: TimeInterval = 0.3
    /// At most this many steps for one event (a fast flick).
    public static let maxStepsPerEvent = 3

    private var accumulated = 0.0
    private var lastTime: TimeInterval = -.infinity

    public init() {}

    public mutating func reset() { accumulated = 0; lastTime = -.infinity }

    /// - Parameters:
    ///   - held: the modifiers held for this event (command, option, control, shift only).
    ///   - isTarget: whether the event goes to an application of the list;
    ///     called only when the modifier matches (it may cost a lookup).
    ///   - dy, dx: vertical and horizontal point deltas, as macOS delivers
    ///     them (natural scrolling already applied).
    ///   - momentum: the event belongs to a momentum (inertia) phase.
    ///   - natural: macOS "natural scrolling" setting.
    public mutating func handle(held: KeyModifiers, isTarget: () -> Bool, dy: Double, dx: Double,
                                momentum: Bool, at time: TimeInterval, config: ZoomConfig,
                                natural: Bool) -> Decision {
        guard config.enabled, held == config.modifier, isTarget() else { reset(); return .pass }
        if momentum { return .absorb(steps: 0) }       // inertia after a zoom: swallow, never count
        guard dy != 0, abs(dy) >= abs(dx) else { return .pass }   // horizontal scrolling stays native

        // Measured (2026-11-24, natural scrolling on): wheel up gives dy > 0
        // and should zoom in. With natural scrolling off macOS reverses dy.
        var signed = natural ? dy : -dy
        if config.invert { signed = -signed }

        if time - lastTime > ZoomTracker.idleReset || (accumulated != 0 && (accumulated > 0) != (signed > 0)) {
            accumulated = 0
        }
        lastTime = time
        accumulated += signed
        let step = Double(config.step)
        var steps = 0
        while abs(accumulated) >= step && abs(steps) < ZoomTracker.maxStepsPerEvent {
            let s = accumulated > 0 ? 1 : -1
            steps += s
            accumulated -= Double(s) * step
        }
        if abs(accumulated) >= step { accumulated = accumulated > 0 ? step - 1 : -(step - 1) }  // cap the backlog
        return .absorb(steps: steps)
    }
}
