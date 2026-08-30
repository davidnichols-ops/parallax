import Foundation
import TacticalCore

/// Segment 10 — rapid fingertip Strategema-duel feel.
///
/// These types are purely additive UI state. They are read-only relative to the
/// deterministic `TacticalCore` engine: they observe engine events and
/// `PlayerState` fields that already exist, and never mutate rules, board
/// topology, camera, networking, training, or replay behavior. They give the
/// match HUD and renderer transient hooks for commitment windows, opponent
/// thinking states, tactical tempo/debt, and richer per-action feedback pulses
/// (pulse/forge/sever/seal/counter/yield) so the duel reads as a fast,
/// visible back-and-forth rather than a silent turn resolver.

/// A visible "action commitment window" — the brief UI phase between the moment
/// a player queues an intent and the tick that resolves it. UI-only; it does
/// not delay or alter engine resolution. In solo/hot-seat modes the window
/// lets the player see their locked-in intent before the exchange fires, which
/// is the on-screen "move counter" feel of the Peak Performance duel.
public struct CommitmentWindow: Equatable, Sendable {
    /// The phase of the commitment lifecycle the queued intent is in.
    public enum Phase: String, Sendable, Equatable {
        case locked      // intent queued, awaiting opponent/tick
        case resolving   // tick is being resolved (bot thinking or both queued)
        case resolved    // tick resolved; window holds the result briefly
    }

    public let player: Player
    public let action: ActionKind
    public let targetNode: String?
    public let targetEdge: String?
    public let targetFace: String?
    public var phase: Phase
    /// Engine tick the intent was queued for (state.tick + 1 at queue time).
    public let targetTick: Int

    public init(player: Player, action: ActionKind,
                targetNode: String?, targetEdge: String?, targetFace: String?,
                phase: Phase, targetTick: Int) {
        self.player = player
        self.action = action
        self.targetNode = targetNode
        self.targetEdge = targetEdge
        self.targetFace = targetFace
        self.phase = phase
        self.targetTick = targetTick
    }

    /// A one-line label for the HUD commitment readout.
    public var label: String {
        let name = actionLabel
        let target: String
        switch action {
        case .select, .pulse, .reinforce, .feint:
            target = targetNode ?? "?"
        case .forge, .traverse, .sever, .counter:
            target = targetEdge ?? "?"
        case .seal:
            target = targetFace ?? "?"
        case .yield, .resign:
            target = ""
        }
        return target.isEmpty ? "\(player.label): \(name)" : "\(player.label): \(name) → \(target)"
    }

    private var actionLabel: String {
        switch action {
        case .select: return "Select"
        case .pulse: return "Pulse"
        case .forge: return "Forge"
        case .traverse: return "Traverse"
        case .counter: return "Counter"
        case .sever: return "Sever"
        case .seal: return "Seal"
        case .reinforce: return "Reinforce"
        case .feint: return "Feint"
        case .yield: return "Yield"
        case .resign: return "Resign"
        }
    }
}

/// The opponent's visible thinking state — what the duel reads as the
/// adversary's tempo. Derived from `botThinking` and the queued-command set,
/// never from private bot internals. In hot-seat both players are human, so the
/// state reflects the waiting player's input phase instead.
public enum OpponentTempo: String, Sendable, Equatable {
    case idle         // no match, or opponent has not begun thinking
    case deliberating // bot search in flight, or waiting for the other human
    case committed    // opponent intent is queued, awaiting resolution
    case reacting     // tick is resolving (shared with the player's resolving phase)

    /// A short HUD caption for the state.
    public var caption: String {
        switch self {
        case .idle: return "STANDBY"
        case .deliberating: return "DELIBERATING"
        case .committed: return "COMMITTED"
        case .reacting: return "REACTING"
        }
    }
}

/// Tactical tempo / debt — a read-only summary of the match's pressure balance
/// computed from existing `PlayerState` fields (flux, initiative, composure,
/// parity, moves). It gives the player a fast "am I ahead or behind" cue
/// without adding any new engine state. Pure function of the engine snapshot.
public struct TacticalTempo: Equatable, Sendable {
    /// A coarse label for the active player's tempo, derived from the tempo
    /// score. Used for the HUD tempo chip color and caption.
    public enum Label: String, Sendable, Equatable {
        case surging     // clearly ahead on tempo
        case balanced    // within the parity band
        case pressured   // falling behind
        case struggling  // deep tactical debt

        public var caption: String {
            switch self {
            case .surging: return "SURGING"
            case .balanced: return "BALANCED"
            case .pressured: return "PRESSURED"
            case .struggling: return "DEBT"
            }
        }
    }

    /// Active player's flux as a 0...1 ratio of `Balance.maxFlux`.
    public let fluxRatio: Double
    /// Active player's initiative minus opponent's initiative.
    public let initiativeDelta: Int
    /// Active player's composure minus opponent's composure.
    public let composureDelta: Int
    /// Current parity value from the engine state.
    public let parity: Int
    /// Active player's move count minus opponent's move count.
    public let moveDelta: Int
    /// The coarse label derived from `score`.
    public let label: Label
    /// A signed tempo score (positive = ahead). Computed deterministically.
    public let score: Int

    /// Compute the tempo for `active` against `opponent` from their states.
    /// Pure; no engine mutation. Uses integer hundredths internally and only
    /// converts the flux ratio to Double for the read-only field.
    public init(active: PlayerState, opponent: PlayerState, parity: Int) {
        self.fluxRatio = Double(active.flux) / Double(max(1, Balance.maxFlux))
        self.initiativeDelta = active.initiative - opponent.initiative
        self.composureDelta = active.composure - opponent.composure
        self.parity = parity
        self.moveDelta = active.moves - opponent.moves

        // Deterministic integer tempo score. Positive = active player ahead.
        // Flux deficit is the heaviest signal (no flux = no moves), then
        // composure, then initiative, then move tempo. Parity is signed from
        // the active player's perspective (positive = active leads).
        let fluxScore = (active.flux - opponent.flux) / 250   // 0..40 range
        let compScore = active.composure - opponent.composure
        let initScore = active.initiative - opponent.initiative
        let moveScore = active.moves - opponent.moves
        // Parity: the engine's parity is symmetric; treat magnitude as pressure.
        let parityScore = -parity   // convention: positive parity favors active
        let total = fluxScore + compScore + initScore + moveScore + parityScore
        self.score = total

        switch total {
        case 12...:   label = .surging
        case 4..<12:  label = .balanced
        case -12..<4: label = .pressured
        default:      label = .struggling
        }
    }
}

/// A transient per-action feedback pulse — a UI/renderer animation hook fired
/// when an action resolves. The HUD and board view observe the latest pulse and
/// the monotonic `token` to trigger a short accent (flash, ring, ripple) for
/// the six authored fingertip actions plus yield and rejection. UI-only; never
/// mutates engine state. Derived from engine events in `resolveTick`.
public enum FeedbackPulse: Equatable, Sendable {
    case pulse(nodeId: String, player: Player)
    case forge(edgeId: String, player: Player)
    case sever(edgeId: String, player: Player)
    case seal(faceId: String, player: Player)
    case counter(edgeId: String, player: Player)
    case traverse(edgeId: String, player: Player)
    case yield(player: Player)
    case reject(player: Player)
    case contested(nodeId: String, player: Player)

    /// The player associated with the pulse (for color routing).
    public var player: Player {
        switch self {
        case .pulse(_, let p), .forge(_, let p), .sever(_, let p),
             .seal(_, let p), .counter(_, let p), .traverse(_, let p),
             .yield(let p), .reject(let p), .contested(_, let p):
            return p
        }
    }

    /// A short HUD caption for the pulse.
    public var caption: String {
        switch self {
        case .pulse: return "PULSE"
        case .forge: return "FORGE"
        case .sever: return "SEVER"
        case .seal: return "SEAL"
        case .counter: return "COUNTER"
        case .traverse: return "TRAVERSE"
        case .yield: return "YIELD"
        case .reject: return "REJECTED"
        case .contested: return "CONTESTED"
        }
    }

    /// Map an engine event to a feedback pulse. Returns nil for events that
    /// do not map to a fingertip accent (cursor moves, scoring, tick resolved,
    /// composure/parity changes, feint registration, match endings). Pure.
    public static func from(_ event: Event) -> FeedbackPulse? {
        guard let player = event.player else { return nil }
        switch event.type {
        case .nodePulsed:
            return .pulse(nodeId: event.payload["node"] ?? "", player: player)
        case .nodeContested:
            return .contested(nodeId: event.payload["node"] ?? "", player: player)
        case .linkForged:
            return .forge(edgeId: event.payload["edge"] ?? "", player: player)
        case .linkSevered:
            return .sever(edgeId: event.payload["edge"] ?? "", player: player)
        case .cycleSealed:
            return .seal(faceId: event.payload["face"] ?? "", player: player)
        case .vectorCountered:
            return .counter(edgeId: event.payload["edge"] ?? "", player: player)
        case .conduitTraversed:
            return .traverse(edgeId: event.payload["edge"] ?? "", player: player)
        case .yieldIssued:
            return .yield(player: player)
        case .actionRejected:
            return .reject(player: player)
        default:
            return nil
        }
    }
}
