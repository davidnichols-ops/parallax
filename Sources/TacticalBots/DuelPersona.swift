import Foundation
import TacticalCore

/// Segment 12 — the grandmaster duel persona layer.
///
/// This module is purely additive and observation-only relative to the
/// deterministic `TacticalCore` engine and the existing `GrandmasterBot`. It
/// gives the AI opponent the *feel* of a convincing grandmaster duel adversary
/// inspired by the Strategema contest — distinct strategy personalities with
/// visible thinking states, bluff/feint cues, bounded adaptive difficulty, and
/// replayable decision explanations — **without copying any copyrighted
/// dialogue, character names, or assets**. All persona names, voice lines, and
/// thinking vocabulary below are original.
///
/// Design constraints (preserved):
/// - Deterministic `TacticalCore` rules are never mutated. Every function here
///   is a pure read of `GameState` / `Command`.
/// - Segment 8 networking, Segment 9 renderer scoring, Segment 10/11
///   tempo/commitment/feedback hooks, training/replay compatibility, haptics,
///   audio, and release scripts are untouched. This layer is a companion
///   observation surface that the HUD may read; it does not alter those paths.
/// - Replay safety: a `DecisionExplanation` is reconstructable from
///   `(Command, GameState, DuelPersona)` alone — no extra replay fields. The
///   classifier re-derives the decision priority from the chosen command and
///   state using the same priority ordering as `GrandmasterBot.chooseCommand`,
///   so a replay can explain any bot move without storing new data.
/// - Adaptive difficulty is bounded: it never exceeds the configured tier's
///   noise budget and never drops below zero. It only nudges within the tier.

/// A named grandmaster duel persona. Wraps an existing `Personality` (which
/// drives the deterministic eval weights) and adds an original display name,
/// a short pre-match taunt, a thinking-state vocabulary, and a voice for
/// decision explanations. The persona is a presentation layer; the underlying
/// `Personality` weights and `Difficulty` search budget are unchanged.
public struct DuelPersona: Sendable, Equatable, Hashable {
    public let id: String
    public let displayName: String
    public let personality: GrandmasterBot.Personality
    /// A short, original pre-match line. No copyrighted dialogue.
    public let preMatchLine: String
    /// Vocabulary shown while the opponent is visibly deliberating, keyed by
    /// thinking phase. All original phrasing.
    public let thinkingVocabulary: [ThinkingPhase: String]
    /// A short voice template for each decision priority. `{target}` is
    /// substituted with the move's target label at explanation time.
    public let voiceTemplates: [DecisionPriority: String]

    public init(id: String, displayName: String,
                personality: GrandmasterBot.Personality,
                preMatchLine: String,
                thinkingVocabulary: [ThinkingPhase: String],
                voiceTemplates: [DecisionPriority: String]) {
        self.id = id
        self.displayName = displayName
        self.personality = personality
        self.preMatchLine = preMatchLine
        self.thinkingVocabulary = thinkingVocabulary
        self.voiceTemplates = voiceTemplates
    }

    /// The authored persona catalog. Each maps to one of the four existing
    /// `Personality` weight sets so the deterministic eval is unchanged; only
    /// the visible duel flavor differs. Names and lines are original.
    public static let catalog: [DuelPersona] = [
        DuelPersona(
            id: "architect",
            displayName: "The Architect",
            personality: .defensive,
            preMatchLine: "I will build what you cannot reach.",
            thinkingVocabulary: [
                .scanning: "Surveying the lattice…",
                .threatening: "A closure forms.",
                .disrupting: "Your line frays.",
                .consolidating: "Extending the frame.",
                .bluffing: "Letting you overreach.",
                .committing: "The structure holds."
            ],
            voiceTemplates: [
                .seal: "Closing region {target} — the frame is mine.",
                .forgeComplete: "Forging {target} — one edge from closure.",
                .targetForge: "Building toward {target}.",
                .forgeExpand: "Linking {target} to extend the network.",
                .pulseExpand: "Claiming {target} — territory grows.",
                .severDisrupt: "Severing {target} — your supply breaks.",
                .evaluate: "Holding position at {target}.",
                .yield: "I yield this exchange. The frame endures.",
                .feint: "Feinting at {target} — read it if you can.",
                .reinforce: "Reinforcing {target} — the anchor holds.",
                .traverse: "Crossing to {target} — new ground.",
                .counter: "Countering {target} — your vector stops."
            ]
        ),
        DuelPersona(
            id: "striker",
            displayName: "The Striker",
            personality: .aggressive,
            preMatchLine: "I will not let you finish what you start.",
            thinkingVocabulary: [
                .scanning: "Reading your intent…",
                .threatening: "I see the seal.",
                .disrupting: "Cutting your line.",
                .consolidating: "Pressing outward.",
                .bluffing: "Inviting your mistake.",
                .committing: "Striking now."
            ],
            voiceTemplates: [
                .seal: "Sealing {target} — points are mine.",
                .forgeComplete: "Forging {target} — closure next.",
                .targetForge: "Driving at {target}.",
                .forgeExpand: "Linking {target} — the net tightens.",
                .pulseExpand: "Pulsing {target} — I take ground.",
                .severDisrupt: "Severing {target} — you lose the line.",
                .evaluate: "Pressing through {target}.",
                .yield: "A breath only. I strike again soon.",
                .feint: "Feinting at {target} — flinch, and you lose.",
                .reinforce: "Reinforcing {target} — the push continues.",
                .traverse: "Crossing to {target} — I follow you.",
                .counter: "Countering {target} — stopped cold."
            ]
        ),
        DuelPersona(
            id: "equilibrium",
            displayName: "The Equilibrium",
            personality: .standoff,
            preMatchLine: "I will not be drawn out of balance.",
            thinkingVocabulary: [
                .scanning: "Measuring the parity…",
                .threatening: "A closure tempts.",
                .disrupting: "Restoring balance.",
                .consolidating: "Holding the center.",
                .bluffing: "Yielding ground you cannot use.",
                .committing: "The balance shifts."
            ],
            voiceTemplates: [
                .seal: "Sealing {target} — parity permits it.",
                .forgeComplete: "Forging {target} — closure maintains balance.",
                .targetForge: "Building at {target} — measured.",
                .forgeExpand: "Linking {target} — symmetry preserved.",
                .pulseExpand: "Pulsing {target} — equal exchange.",
                .severDisrupt: "Severing {target} — your excess corrected.",
                .evaluate: "Holding at {target} — the contest stays even.",
                .yield: "I yield. Parity is the game.",
                .feint: "Feinting at {target} — balance reveals nothing.",
                .reinforce: "Reinforcing {target} — the center holds.",
                .traverse: "Crossing to {target} — equal reach.",
                .counter: "Countering {target} — equilibrium restored."
            ]
        ),
        DuelPersona(
            id: "vector",
            displayName: "The Vector",
            personality: .balanced,
            preMatchLine: "I read the board as it reads you.",
            thinkingVocabulary: [
                .scanning: "Mapping the field…",
                .threatening: "A line closes.",
                .disrupting: "Your vector is exposed.",
                .consolidating: "Expanding the read.",
                .bluffing: "Showing you a false pattern.",
                .committing: "The read is complete."
            ],
            voiceTemplates: [
                .seal: "Sealing {target} — the read was correct.",
                .forgeComplete: "Forging {target} — closure follows the pattern.",
                .targetForge: "Building at {target} — the field suggests it.",
                .forgeExpand: "Linking {target} — the network extends.",
                .pulseExpand: "Pulsing {target} — territory per the read.",
                .severDisrupt: "Severing {target} — your line was predicted.",
                .evaluate: "Holding at {target} — the read favors patience.",
                .yield: "Yielding — no line worth taking yet.",
                .feint: "Feinting at {target} — a false pattern for you.",
                .reinforce: "Reinforcing {target} — stabilizing the read.",
                .traverse: "Crossing to {target} — new data.",
                .counter: "Countering {target} — predicted and stopped."
            ]
        )
    ]

    /// Look up a persona by id, falling back to the balanced `vector` persona.
    public static func resolve(_ id: String) -> DuelPersona {
        catalog.first { $0.id == id } ?? catalog.first { $0.personality == .balanced } ?? catalog[3]
    }

    /// The default persona (The Vector / balanced).
    public static let `default`: DuelPersona = catalog[3]

    /// Resolve a persona from an existing `Personality`, picking the catalog
    /// entry whose weights match. Deterministic.
    public static func from(personality: GrandmasterBot.Personality) -> DuelPersona {
        catalog.first { $0.personality == personality } ?? .default
    }
}

/// A visible thinking phase the opponent projects while deliberating or just
/// after committing. Derived purely from the chosen `Command` and `GameState`
/// via `DuelPersona.thinkingPhase(for:state:)`, so it is deterministic and
/// replay-safe. This is a companion to the Segment 10 `OpponentTempo` chip:
/// `OpponentTempo` says *whether* the opponent is thinking; `ThinkingPhase`
/// says *what kind* of thought the chosen move represents.
public enum ThinkingPhase: String, Sendable, Equatable, Hashable, CaseIterable {
    case scanning       // evaluating the field, no salient closure
    case threatening    // found a seal or face-completing forge
    case disrupting     // found a critical sever of an enemy near-complete face
    case consolidating  // pulse/reinforce expansion toward an anchor
    case bluffing       // feint or yield — projecting weakness or misdirection
    case committing     // a decisive forge/seal/traverse that locks a plan

    /// A short HUD caption for the phase.
    public var caption: String {
        switch self {
        case .scanning:       return "SCANNING"
        case .threatening:    return "THREATENING"
        case .disrupting:     return "DISRUPTING"
        case .consolidating:  return "CONSOLIDATING"
        case .bluffing:       return "BLUFFING"
        case .committing:     return "COMMITTING"
        }
    }
}

/// The decision priority that produced a bot move. Mirrors the priority
/// ordering in `GrandmasterBot.chooseCommand` so a chosen command can be
/// classified after the fact (pure, deterministic, replay-safe). Used to drive
/// the thinking phase and the persona voice line.
public enum DecisionPriority: String, Sendable, Equatable, Hashable, CaseIterable {
    case seal           // Priority 1: seal a sealable face
    case forgeComplete  // Priority 2: forge the missing edge of a 3/4 face
    case targetForge    // Priority 3: forge toward the anchor's target face
    case forgeExpand    // Priority 4: forge to build edge density
    case pulseExpand    // Priority 5: pulse to expand toward anchor
    case severDisrupt   // Priority 6: sever an enemy near-complete face
    case evaluate       // Priority 7: standard evaluation picked this move
    case yield          // no active move / explicit yield
    case feint          // feint action
    case reinforce      // reinforce anchor
    case traverse       // traverse a conduit
    case counter        // counter an enemy vector
}

/// A structured, replayable explanation of a bot move. Reconstructable from
/// `(Command, GameState, DuelPersona)` via `DuelPersona.structuredExplanation`
/// — no extra replay fields are required. The `voiceLine` is the persona's
/// original phrasing; `reasoning` is a deterministic, persona-neutral summary
/// of why the move was selected (which priority fired and the board context).
public struct DecisionExplanation: Sendable, Equatable, Hashable {
    public let priority: DecisionPriority
    public let action: ActionKind
    public let targetLabel: String
    public let thinkingPhase: ThinkingPhase
    public let voiceLine: String
    public let reasoning: String

    public init(priority: DecisionPriority, action: ActionKind,
                targetLabel: String, thinkingPhase: ThinkingPhase,
                voiceLine: String, reasoning: String) {
        self.priority = priority
        self.action = action
        self.targetLabel = targetLabel
        self.thinkingPhase = thinkingPhase
        self.voiceLine = voiceLine
        self.reasoning = reasoning
    }
}

/// Bounded adaptive difficulty. Given the configured `Difficulty` tier and the
/// current match state, returns an *effective noise budget* that stays within
/// `[0, tier.noise]`. When the bot is clearly ahead it may relax slightly
/// (more noise, more human-readable variation); when it is behind it tightens
/// (less noise, sharper play). The nudge is bounded so the configured tier is
/// never exceeded — a `novice` bot never becomes sharper than `novice`'s max
/// noise, and a `grandmaster` bot (noise 0) is unaffected.
///
/// Pure and deterministic: a function of `GameState` and the configured tier
/// only. It does NOT mutate the bot's search depth or transposition table; it
/// only adjusts the noise term applied during evaluation, within the tier's
/// own budget. This preserves determinism (same state + seed → same move)
/// because the noise is still drawn from the bot's `SeededRNG` and the
/// effective budget is a pure function of state.
public enum AdaptiveDifficulty {
    /// The effective noise budget for the configured tier at the current
    /// state. Bounded to `[0, tier.noise]`.
    public static func effectiveNoise(configured: GrandmasterBot.Difficulty,
                                      state: GameState,
                                      botPlayer: Player) -> Float {
        let maxNoise = configured.noise
        guard maxNoise > 0 else { return 0 }  // master/grandmaster: no noise ever
        let myScore = Float(Scoring.computeScore(botPlayer, state: state))
        let oppScore = Float(Scoring.computeScore(botPlayer.opponent, state: state))
        let delta = myScore - oppScore
        // Ahead by >= 30 → relax up to +20% of budget (capped at maxNoise).
        // Behind by >= 30 → tighten down to 60% of budget.
        // Within ±30 → stay at the configured budget.
        let nudge: Float
        switch delta {
        case 30...:   nudge = maxNoise * 0.20
        case ..<(-30): nudge = -maxNoise * 0.40
        default:       nudge = 0
        }
        let effective = maxNoise + nudge
        return min(maxNoise, max(0, effective))
    }

    /// A coarse adaptive label for the HUD: whether the bot is currently
    /// relaxing, holding, or tightening relative to its configured tier.
    public enum Adaptation: String, Sendable, Equatable {
        case relaxing   // ahead → slightly more variation
        case holding    // within the parity band
        case tightening // behind → sharper play

        public var caption: String {
            switch self {
            case .relaxing:   return "EASING"
            case .holding:    return "STEADY"
            case .tightening: return "PRESSING"
            }
        }
    }

    /// The coarse adaptation label for the current state. Pure.
    public static func adaptation(configured: GrandmasterBot.Difficulty,
                                  state: GameState,
                                  botPlayer: Player) -> Adaptation {
        guard configured.noise > 0 else { return .holding }
        let myScore = Scoring.computeScore(botPlayer, state: state)
        let oppScore = Scoring.computeScore(botPlayer.opponent, state: state)
        let delta = myScore - oppScore
        switch delta {
        case 30...:    return .relaxing
        case ..<(-30): return .tightening
        default:       return .holding
        }
    }
}

// MARK: - DuelPersona pure derivations

public extension DuelPersona {

    /// Classify which decision priority produced `command` against `state`.
    /// Pure and deterministic — re-derives the priority using the same ordering
    /// as `GrandmasterBot.chooseCommand`, so it is replay-safe (no stored
    /// priority needed). The classifier inspects only the command and the
    /// public `GameState`.
    func decisionPriority(for command: Command, state: GameState) -> DecisionPriority {
        let player = command.player
        switch command.action {
        case .seal:
            return .seal
        case .feint:
            return .feint
        case .reinforce:
            return .reinforce
        case .traverse:
            return .traverse
        case .counter:
            return .counter
        case .sever:
            // A sever is "disrupting" only if it breaks an enemy near-complete
            // face (Priority 6); otherwise it fell out of standard evaluation.
            if severBreaksNearCompleteFace(command, state: state, player: player) {
                return .severDisrupt
            }
            return .evaluate
        case .forge:
            if forgeCompletesFace(command, state: state, player: player) {
                return .forgeComplete
            }
            if forgeTargetsAnchorFace(command, state: state, player: player) {
                return .targetForge
            }
            // Priority 4 (forgeExpand) vs Priority 7 (evaluate): if the player
            // owns >= 3 nodes and few edges, the forge is an expansion forge.
            let ownedNodes = state.board.nodes.filter {
                state.nodes[$0.id]?.owner == player.owner
            }
            let myEdges = state.edges.values.filter { $0.owner == player.owner }.count
            if ownedNodes.count >= 3 && myEdges < ownedNodes.count * 2 {
                return .forgeExpand
            }
            return .evaluate
        case .pulse:
            // Priority 5 (pulseExpand) applies when the player owns < 6 nodes;
            // otherwise the pulse came from standard evaluation.
            let ownedNodes = state.board.nodes.filter {
                state.nodes[$0.id]?.owner == player.owner
            }
            return ownedNodes.count < 6 ? .pulseExpand : .evaluate
        case .yield:
            return .yield
        case .select, .resign:
            return .evaluate
        }
    }

    /// The visible thinking phase for a chosen move. Pure; derived from the
    /// decision priority. This is the "what kind of thought" companion to the
    /// Segment 10 `OpponentTempo` "whether thinking" chip.
    func thinkingPhase(for command: Command, state: GameState) -> ThinkingPhase {
        let priority = decisionPriority(for: command, state: state)
        switch priority {
        case .seal, .forgeComplete:    return .threatening
        case .severDisrupt:            return .disrupting
        case .targetForge, .forgeExpand, .pulseExpand, .reinforce: return .consolidating
        case .traverse, .counter:      return .committing
        case .feint, .yield:           return .bluffing
        case .evaluate:                return .scanning
        }
    }

    /// A short target label for a command (node id, edge id, or face id).
    static func targetLabel(for command: Command) -> String {
        switch command.action {
        case .select, .pulse, .reinforce, .feint:
            return command.targetNodeId ?? "?"
        case .forge, .traverse, .sever, .counter:
            return command.targetEdgeId ?? "?"
        case .seal:
            return command.candidateCycleId ?? "?"
        case .yield, .resign:
            return ""
        }
    }

    /// A structured, replayable explanation of a bot move. Pure: reconstructable
    /// from `(Command, GameState, DuelPersona)` alone. The `voiceLine` uses the
    /// persona's original template; `reasoning` is a persona-neutral summary.
    func structuredExplanation(for command: Command, state: GameState) -> DecisionExplanation {
        let priority = decisionPriority(for: command, state: state)
        let phase = thinkingPhase(for: command, state: state)
        let target = DuelPersona.targetLabel(for: command)
        let template = voiceTemplates[priority] ?? voiceTemplates[.evaluate] ?? "Move to {target}."
        let voiceLine = template.replacingOccurrences(of: "{target}", with: target.isEmpty ? "the board" : target)
        let reasoning = neutralReasoning(for: command, state: state, priority: priority)
        return DecisionExplanation(
            priority: priority,
            action: command.action,
            targetLabel: target,
            thinkingPhase: phase,
            voiceLine: voiceLine,
            reasoning: reasoning
        )
    }

    /// The deliberation vocabulary line for a thinking phase, with a fallback.
    func deliberationLine(for phase: ThinkingPhase) -> String {
        thinkingVocabulary[phase] ?? "Considering…"
    }

    // MARK: - Private classifiers (mirror GrandmasterBot priority logic)

    private func forgeCompletesFace(_ command: Command, state: GameState, player: Player) -> Bool {
        guard command.action == .forge, let eid = command.targetEdgeId else { return false }
        for face in state.board.faces where face.boundary.contains(eid) {
            var myBoundary = 0
            var missing: String? = nil
            for fid in face.boundary {
                guard let es = state.edges[fid] else { continue }
                if es.severed { myBoundary = -1; break }
                if es.owner == player.owner {
                    myBoundary += 1
                } else if es.owner == .neutral {
                    missing = fid
                } else {
                    myBoundary = -1; break
                }
            }
            if myBoundary == 3, missing == eid { return true }
        }
        return false
    }

    private func forgeTargetsAnchorFace(_ command: Command, state: GameState, player: Player) -> Bool {
        guard command.action == .forge, let eid = command.targetEdgeId else { return false }
        let anchor = player == .player1
            ? state.board.anchors.player1.first
            : state.board.anchors.player2.first
        guard let anchorId = anchor, let anchorNode = state.board.nodeMap[anchorId] else { return false }
        let plateauFaces = state.board.faces.filter { $0.plateau == anchorNode.plateau }
        for face in plateauFaces where face.boundary.contains(eid) {
            var hasEnemy = false
            for fid in face.boundary {
                if state.edges[fid]?.owner == player.opponent.owner { hasEnemy = true; break }
            }
            if !hasEnemy { return true }
        }
        return false
    }

    private func severBreaksNearCompleteFace(_ command: Command, state: GameState, player: Player) -> Bool {
        guard command.action == .sever, let eid = command.targetEdgeId else { return false }
        let opp = player.opponent
        for face in state.board.faces where face.boundary.contains(eid) {
            var oppBoundary = 0
            for fid in face.boundary {
                guard let es = state.edges[fid] else { continue }
                if es.severed { oppBoundary = -1; break }
                if es.owner == opp.owner { oppBoundary += 1 }
                else if es.owner == .neutral { /* keep counting */ }
                else { oppBoundary = -1; break }
            }
            if oppBoundary >= 3 { return true }
        }
        return false
    }

    private func neutralReasoning(for command: Command, state: GameState,
                                  priority: DecisionPriority) -> String {
        let target = DuelPersona.targetLabel(for: command)
        switch priority {
        case .seal:
            return "Seal closes a controlled region for score + cycle bonus."
        case .forgeComplete:
            return "Forge completes a 3/4-edge region; one edge from closure."
        case .targetForge:
            return "Forge builds toward the anchor plateau's target region\(target.isEmpty ? "" : " via \(target)")."
        case .forgeExpand:
            return "Forge raises edge density with \(target.isEmpty ? "the board" : target); few edges relative to nodes."
        case .pulseExpand:
            return "Pulse captures neutral territory\(target.isEmpty ? "" : " at \(target)") while node count is low."
        case .severDisrupt:
            return "Sever breaks an opponent near-complete region\(target.isEmpty ? "" : " at \(target)")."
        case .evaluate:
            return "Standard evaluation selected this move\(target.isEmpty ? "" : " targeting \(target)")."
        case .yield:
            return "No high-value move this exchange; yield preserves flux."
        case .feint:
            return "Feint projects intent at \(target.isEmpty ? "the board" : target) without committing."
        case .reinforce:
            return "Reinforce stabilizes the anchor\(target.isEmpty ? "" : " at \(target)")."
        case .traverse:
            return "Traverse opens a new plateau\(target.isEmpty ? "" : " via \(target)")."
        case .counter:
            return "Counter parries a recent enemy vector\(target.isEmpty ? "" : " at \(target)")."
        }
    }
}

// MARK: - GrandmasterBot persona convenience

public extension GrandmasterBot {
    /// The persona matching this bot's configured `personality`. Deterministic.
    var duelPersona: DuelPersona {
        DuelPersona.from(personality: personality)
    }

    /// A structured, replayable explanation of `command` using the bot's
    /// persona voice. Pure; reconstructable from `(command, state, persona)`.
    func structuredExplanation(for command: Command, state: GameState) -> DecisionExplanation {
        duelPersona.structuredExplanation(for: command, state: state)
    }

    /// The visible thinking phase for `command`. Pure; replay-safe.
    func thinkingPhase(for command: Command, state: GameState) -> ThinkingPhase {
        duelPersona.thinkingPhase(for: command, state: state)
    }

    /// The bounded adaptive noise budget at the current state. Pure.
    func adaptiveNoise(at state: GameState) -> Float {
        AdaptiveDifficulty.effectiveNoise(configured: difficulty, state: state, botPlayer: player)
    }

    /// The coarse adaptive label at the current state. Pure.
    func adaptiveLabel(at state: GameState) -> AdaptiveDifficulty.Adaptation {
        AdaptiveDifficulty.adaptation(configured: difficulty, state: state, botPlayer: player)
    }
}
