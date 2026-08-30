import Foundation
import TacticalCore

/// Segment 11 — renderer-observable feedback tokens.
///
/// The duel-feel state in `ParallaxApp` (commitment windows, feedback pulses)
/// lives above the renderer in the dependency graph, so the renderer cannot
/// import it. These value types are the renderer's own observation surface:
/// the app maps its Segment 10 state into them and passes them down through
/// `BoardMetalView` on every SwiftUI update. The renderer compares the
/// monotonic `token` to detect a new pulse/glow and triggers a short board
/// accent (burst, flash, ripple, snapback) on the resolved target.
///
/// All renderer-only; never mutates engine, topology, networking, training,
/// or replay state. Animations are gated on `reduceMotion`; the scene graph
/// stays headless-testable.

/// A transient per-action feedback pulse the board can animate. Mirrors the
/// app-layer `FeedbackPulse` but lives in the renderer so the renderer can
/// observe it without an upward dependency. The `token` is monotonic and lets
/// the renderer re-trigger an animation even when two consecutive pulses are
/// equal (e.g. two pulses on the same node).
public struct BoardFeedbackPulse: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        case pulse
        case forge
        case sever
        case seal
        case counter
        case traverse
        case yield
        case reject
        case contested
    }

    public let kind: Kind
    public let player: Player
    public let targetNode: String?
    public let targetEdge: String?
    public let targetFace: String?
    /// Monotonic observation token. The renderer fires an accent only when this
    /// differs from the last applied token, so repeated pulses re-trigger.
    public let token: Int

    public init(kind: Kind, player: Player,
                targetNode: String?, targetEdge: String?, targetFace: String?,
                token: Int) {
        self.kind = kind
        self.player = player
        self.targetNode = targetNode
        self.targetEdge = targetEdge
        self.targetFace = targetFace
        self.token = token
    }
}

/// A visible commitment-window glow the board holds on the targeted
/// node/edge/face while a player's intent is locked in or resolving. Mirrors
/// the app-layer `CommitmentWindow` target + phase for the renderer. The glow
/// attaches when the window opens, persists through `.locked`/`.resolving`,
/// and fades when the phase reaches `.resolved` (or when the glow is nil).
public struct BoardCommitmentGlow: Equatable, Sendable {
    public enum Phase: String, Sendable, Equatable {
        case locked
        case resolving
        case resolved
    }

    public let player: Player
    public let targetNode: String?
    public let targetEdge: String?
    public let targetFace: String?
    public let phase: Phase
    /// Monotonic observation token. Changes whenever the glow should update
    /// (new target, phase transition, or clear).
    public let token: Int

    public init(player: Player, targetNode: String?, targetEdge: String?,
                targetFace: String?, phase: Phase, token: Int) {
        self.player = player
        self.targetNode = targetNode
        self.targetEdge = targetEdge
        self.targetFace = targetFace
        self.phase = phase
        self.token = token
    }
}
