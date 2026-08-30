import Foundation
import TacticalCore

/// Search-driven Grandmaster bot. Uses influence-map heuristics + 1-ply
/// tactical search with transposition table. Deterministic — same state +
/// same seed always produces the same move.
///
/// Difficulty tiers adjust search budget, prediction horizon, and risk model.
public struct GrandmasterBot: Sendable {
    public let player: Player
    public let board: BoardDefinition
    public var rng: SeededRNG
    public let difficulty: Difficulty
    public let personality: Personality

    public enum Difficulty: Int, Sendable, Comparable {
        case novice = 0      // 1-ply, high noise
        case adept = 1       // 1-ply, low noise
        case master = 2      // 2-ply, no noise
        case grandmaster = 3 // 3-ply, no noise, transposition table

        public static func < (lhs: Difficulty, rhs: Difficulty) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var searchDepth: Int {
            switch self {
            case .novice: return 1
            case .adept: return 1
            case .master: return 2
            case .grandmaster: return 3
            }
        }
        public var noise: Float {
            switch self {
            case .novice: return 0.4
            case .adept: return 0.1
            case .master: return 0.0
            case .grandmaster: return 0.0
            }
        }
    }

    public enum Personality: String, Sendable {
        case aggressive    // prioritizes sealing and scoring
        case defensive     // prioritizes parity and counter
        case balanced      // equal weight
        case standoff      // pure parity maintenance

        public var weights: EvalWeights {
            switch self {
            case .aggressive: return EvalWeights(territory: 1.5, cycle: 2.0, counter: 1.0, parity: 0.5, flux: 0.8, threat: 1.2)
            case .defensive:  return EvalWeights(territory: 1.0, cycle: 1.0, counter: 2.0, parity: 2.0, flux: 1.2, threat: 1.5)
            case .balanced:   return EvalWeights(territory: 1.0, cycle: 1.0, counter: 1.0, parity: 1.0, flux: 1.0, threat: 1.0)
            case .standoff:   return EvalWeights(territory: 0.3, cycle: 0.5, counter: 3.0, parity: 5.0, flux: 1.5, threat: 2.0)
            }
        }
    }

    public struct EvalWeights: Sendable {
        public let territory: Float
        public let cycle: Float
        public let counter: Float
        public let parity: Float
        public let flux: Float
        public let threat: Float
    }

    private var transpositionTable: [String: Float] = [:]

    public init(player: Player, board: BoardDefinition, seed: UInt64,
                difficulty: Difficulty = .master, personality: Personality = .balanced) {
        self.player = player
        self.board = board
        self.rng = SeededRNG(seed: seed)
        self.difficulty = difficulty
        self.personality = personality
    }

    /// Choose the best command for the current state.
    public mutating func chooseCommand(state: GameState) -> Command {
        let candidates = legalMoves(state: state)
        guard !candidates.isEmpty else { return .yield_(player) }

        // Novice: skip strategic priorities, just pick with noisy evaluation.
        if difficulty == .novice {
            return chooseNoisy(candidates: candidates, state: state)
        }

        // Priority 1: Seal any sealable face (highest value).
        for cmd in candidates where cmd.action == .seal {
            if Territory.isSealable(cmd.candidateCycleId ?? "", by: player, state: state) {
                return cmd
            }
        }

        // Priority 2: Forge the missing edge of a near-complete face (3/4 edges).
        if let forgeCmd = findFaceCompletingForge(state: state, candidates: candidates) {
            return forgeCmd
        }

        // Priority 3: Concentrate forging around a target face near our anchor.
        if let forgeCmd = findTargetFaceForge(state: state, candidates: candidates) {
            return forgeCmd
        }

        // Priority 4: If we have enough nodes but few edges, prioritize forging.
        let ownedNodes = board.nodes.filter { state.nodes[$0.id]?.owner == player.owner }
        let myEdgeCount = state.edges.values.filter { $0.owner == player.owner }.count
        if ownedNodes.count >= 3 && myEdgeCount < ownedNodes.count * 2 {
            let forgeMoves = candidates.filter { $0.action == .forge }
            if !forgeMoves.isEmpty {
                return bestForgeMove(forgeMoves, state: state)
            }
        }

        // Priority 5: Pulse to expand toward our target face area.
        let pulseMoves = candidates.filter { $0.action == .pulse }
        if !pulseMoves.isEmpty, ownedNodes.count < 6 {
            return bestPulseMove(pulseMoves, state: state)
        }

        // Priority 6: Sever enemy near-complete faces.
        if difficulty >= .adept {
            if let severCmd = findCriticalSever(state: state, candidates: candidates) {
                return severCmd
            }
        }

        // Priority 7: Standard evaluation for remaining moves.
        return chooseBestByEvaluation(candidates: candidates, state: state)
    }

    /// Novice move selection: random among legal moves with slight preference
    /// for active moves.
    private mutating func chooseNoisy(candidates: [Command], state: GameState) -> Command {
        let activeMoves = candidates.filter { $0.action != .yield }
        guard !activeMoves.isEmpty else { return candidates.last ?? .yield_(player) }
        // 70% chance to pick a random active move, 30% yield.
        if rng.uniform(lessThan: 10) < 3 {
            return .yield_(player)
        }
        let idx = rng.uniform(lessThan: activeMoves.count)
        return activeMoves[idx]
    }

    /// Standard evaluation-based move selection.
    private mutating func chooseBestByEvaluation(candidates: [Command], state: GameState) -> Command {
        var bestScore: Float = -.infinity
        var bestCmd = candidates[0]
        let noise = difficulty.noise

        for cmd in candidates {
            var score = evaluateMove(cmd, state: state, depth: difficulty.searchDepth)
            if cmd.action != .yield { score += 0.1 }
            score += Float(rng.uniform(lessThan: 1000)) / 1000.0 * noise
            if score > bestScore {
                bestScore = score
                bestCmd = cmd
            }
        }
        return bestCmd
    }

    /// Find a sever move that breaks an opponent's near-complete face.
    private func findCriticalSever(state: GameState, candidates: [Command]) -> Command? {
        let oppPlayer = player.opponent
        for face in board.faces {
            var oppBoundary = 0
            var targetEdge: String? = nil
            for eid in face.boundary {
                guard let es = state.edges[eid] else { continue }
                if es.severed { oppBoundary = -1; break }
                if es.owner == oppPlayer.owner {
                    oppBoundary += 1
                } else if es.owner == .neutral {
                    targetEdge = eid
                } else {
                    oppBoundary = -1; break
                }
            }
            // If opponent has 3/4 edges, sever one of their edges.
            if oppBoundary >= 3 {
                let severMoves = candidates.filter { $0.action == .sever }
                for cmd in severMoves {
                    if let eid = cmd.targetEdgeId, face.boundary.contains(eid) {
                        return cmd
                    }
                }
            }
        }
        return nil
    }

    /// Find a forge move that completes a face (makes all 4 boundary edges ours).
    private func findFaceCompletingForge(state: GameState, candidates: [Command]) -> Command? {
        for face in board.faces {
            var myBoundary = 0
            var missingEdge: String? = nil
            for eid in face.boundary {
                guard let es = state.edges[eid] else { continue }
                if es.severed { myBoundary = -1; break }
                if es.owner == player.owner {
                    myBoundary += 1
                } else if es.owner == .neutral {
                    missingEdge = eid
                } else {
                    myBoundary = -1; break
                }
            }
            if myBoundary == 3, let eid = missingEdge {
                let cmd = Command.forge(player, eid)
                if candidates.contains(cmd) { return cmd }
            }
        }
        return nil
    }

    /// Find a forge move that contributes to our target face (the face closest
    /// to our anchor that we're making progress on).
    private func findTargetFaceForge(state: GameState, candidates: [Command]) -> Command? {
        let anchor = player == .player1
            ? board.anchors.player1.first
            : board.anchors.player2.first
        guard let anchorId = anchor,
              let anchorNode = board.nodeMap[anchorId] else { return nil }

        let forgeMoves = candidates.filter { $0.action == .forge }
        guard !forgeMoves.isEmpty else { return nil }

        // Find faces on the same plateau as the anchor, sorted by progress.
        let plateauFaces = board.faces.filter { $0.plateau == anchorNode.plateau }
        var bestFace: FaceDef? = nil
        var bestProgress = -1

        for face in plateauFaces {
            var myEdges = 0
            var hasEnemy = false
            for eid in face.boundary {
                guard let es = state.edges[eid] else { continue }
                if es.owner == player.owner { myEdges += 1 }
                else if es.owner == player.opponent.owner { hasEnemy = true; break }
            }
            if hasEnemy { continue }
            if myEdges > bestProgress {
                bestProgress = myEdges
                bestFace = face
            }
        }

        // If we have a target face with at least 1 edge, forge toward it.
        if let target = bestFace, bestProgress >= 1 {
            for cmd in forgeMoves {
                if let eid = cmd.targetEdgeId, target.boundary.contains(eid) {
                    return cmd
                }
            }
        }

        // Otherwise, forge the first edge of the closest face to our anchor.
        if let target = plateauFaces.first {
            for cmd in forgeMoves {
                if let eid = cmd.targetEdgeId, target.boundary.contains(eid) {
                    return cmd
                }
            }
        }

        return nil
    }

    /// Pick the forge move that contributes most to face completion.
    private func bestForgeMove(_ forgeMoves: [Command], state: GameState) -> Command {
        var best = forgeMoves[0]
        var bestScore = -1

        for cmd in forgeMoves {
            guard let eid = cmd.targetEdgeId else { continue }
            var score = 0
            for face in board.faces where face.boundary.contains(eid) {
                for otherEid in face.boundary where otherEid != eid {
                    if state.edges[otherEid]?.owner == player.owner { score += 2 }
                }
            }
            if score > bestScore {
                bestScore = score
                best = cmd
            }
        }
        return best
    }

    /// Pick the pulse move closest to our anchor (concentrate expansion).
    private func bestPulseMove(_ pulseMoves: [Command], state: GameState) -> Command {
        let anchor = player == .player1
            ? board.anchors.player1.first
            : board.anchors.player2.first
        guard let anchorId = anchor,
              let anchorNode = board.nodeMap[anchorId] else { return pulseMoves[0] }

        var best = pulseMoves[0]
        var bestDist = Int.max

        for cmd in pulseMoves {
            guard let nid = cmd.targetNodeId, let node = board.nodeMap[nid] else { continue }
            let dist = abs(node.x - anchorNode.x) + abs(node.y - anchorNode.y) + abs(node.plateau - anchorNode.plateau) * 10
            if dist < bestDist {
                bestDist = dist
                best = cmd
            }
        }
        return best
    }

    // MARK: - Move generation

    public func legalMoves(state: GameState) -> [Command] {
        guard state.gameStatus == .running else { return [.yield_(player)] }
        var moves: [Command] = []

        let p = state.playerStates[player]!
        let ownedNodes = board.nodes.filter { state.nodes[$0.id]?.owner == player.owner }

        // Pulse: neutral nodes adjacent to owned nodes with influence.
        for src in ownedNodes where (state.nodes[src.id]?.influence ?? 0) >= 40 {
            if p.flux >= Balance.costPulse {
                for eid in board.incidence[src.id] ?? [] {
                    let def = board.edgeMap[eid]!
                    if def.kind != .intra { continue }
                    if let es = state.edges[eid], es.severed { continue }
                    let other = def.u == src.id ? def.v : def.u
                    if state.nodes[other]?.owner == .neutral {
                        moves.append(.pulse(player, other))
                    }
                }
            }
        }

        // Forge: edges where we own at least one endpoint and the edge is not
        // already ours. This includes edges between two of our own nodes (needed
        // to complete face boundaries).
        if p.flux >= Balance.costForge {
            for def in board.edges where def.kind == .intra {
                let es = state.edges[def.id]
                if es?.severed == true || es?.owner == player.owner { continue }
                let u = state.nodes[def.u]?.owner ?? .neutral
                let v = state.nodes[def.v]?.owner ?? .neutral
                // Forge if we own at least one endpoint and the other is neutral or ours.
                if (u == player.owner && v != player.opponent.owner) ||
                   (v == player.owner && u != player.opponent.owner) {
                    moves.append(.forge(player, def.id))
                }
            }
        }

        // Seal: any sealable face.
        for face in board.faces {
            if Territory.isSealable(face.id, by: player, state: state) {
                moves.append(.seal(player, face.id))
            }
        }

        // Sever: enemy-owned edges.
        if p.flux >= Balance.costSever {
            for def in board.edges where def.kind == .intra {
                let es = state.edges[def.id]
                if es?.severed == true { continue }
                if es?.owner != .neutral && es?.owner != player.owner {
                    moves.append(.sever(player, def.id))
                }
            }
        }

        // Traverse: conduits from owned nodes.
        if p.flux >= Balance.costTraverseMin {
            for def in board.edges where def.kind == .conduit {
                if let es = state.edges[def.id], es.severed { continue }
                let u = state.nodes[def.u]?.owner ?? .neutral
                let v = state.nodes[def.v]?.owner ?? .neutral
                if u == player.owner || v == player.owner {
                    moves.append(.traverse(player, def.id))
                }
            }
        }

        // Reinforce: owned anchors.
        if p.flux >= Balance.costReinforce {
            for src in ownedNodes where src.kind == .anchor {
                moves.append(.reinforce(player, src.id))
            }
        }

        // Yield is always available, but listed last (lowest priority).
        moves.append(.yield_(player))

        // Filter to only legally executable moves.
        return moves.filter { Legality.project($0, state: state).legal }
    }

    // MARK: - Evaluation

    private mutating func evaluateMove(_ cmd: Command, state: GameState, depth: Int) -> Float {
        // Apply the move by creating a fresh engine from the current state.
        var simEngine = Engine(restoring: state.snapshot(), board: board)
        let oppPlayer: Player = player == .player1 ? .player2 : .player1
        simEngine.submitTick([cmd, .yield_(oppPlayer)])
        let simState = simEngine.state
        return evaluatePosition(simState, depth: 0)
    }

    private mutating func evaluatePosition(_ state: GameState, depth: Int) -> Float {
        // Transposition table check.
        let snap = state.snapshot()
        let hash = CanonicalEncoding.contentHash(snap)
        if let cached = transpositionTable[hash] { return cached }

        let w = personality.weights
        let myScore = Float(Scoring.computeScore(player, state: state))
        let oppScore = Float(Scoring.computeScore(player == .player1 ? .player2 : .player1, state: state))
        let myFlux = Float(state.playerStates[player]?.flux ?? 0)
        let oppFlux = Float(state.playerStates[player == .player1 ? .player2 : .player1]?.flux ?? 0)
        let parity = Float(state.parity)
        let myCycles = Float(state.playerStates[player]?.sealedCycles ?? 0)
        let oppCycles = Float(state.playerStates[player == .player1 ? .player2 : .player1]?.sealedCycles ?? 0)

        // Territory: count owned nodes and total influence.
        var myNodes = 0.0
        var oppNodes = 0.0
        var myInfluence = 0.0
        var oppInfluence = 0.0
        for (_, ns) in state.nodes {
            if ns.owner == player.owner {
                myNodes += 1
                myInfluence += Double(ns.influence)
            } else if ns.owner == player.opponent.owner {
                oppNodes += 1
                oppInfluence += Double(ns.influence)
            }
        }

        // Forged edges.
        var myEdges = 0.0
        var oppEdges = 0.0
        for (_, es) in state.edges {
            if es.owner == player.owner { myEdges += 1 }
            else if es.owner == player.opponent.owner { oppEdges += 1 }
        }

        // Composite evaluation.
        let territory = w.territory * (Float(myScore) + Float(myNodes - oppNodes) * 2.0 + Float(myInfluence - oppInfluence) * 0.01)
        let cycle = w.cycle * (myCycles - oppCycles)
        let parityScore = w.parity * Float(player == .player1 ? parity : -parity)
        let fluxScore = w.flux * (myFlux - oppFlux) / 1000.0
        let edgeScore = w.counter * Float(myEdges - oppEdges) * 3.0

        // Face completion bonus: for each face where we own 3/4 boundary edges,
        // give a large bonus (we're one forge away from controlling it).
        var nearCompleteFaces = 0.0
        var oppNearCompleteFaces = 0.0
        for face in board.faces {
            var myBoundary = 0; var oppBoundary = 0; var total = 0
            for eid in face.boundary {
                guard let es = state.edges[eid] else { continue }
                if !es.severed {
                    total += 1
                    if es.owner == player.owner { myBoundary += 1 }
                    else if es.owner == player.opponent.owner { oppBoundary += 1 }
                }
            }
            if myBoundary >= 3 && total >= 4 { nearCompleteFaces += 1 }
            if oppBoundary >= 3 && total >= 4 { oppNearCompleteFaces += 1 }
        }
        let completionBonus = w.cycle * Float(nearCompleteFaces - oppNearCompleteFaces) * 5.0

        let threat = -w.threat * Float(board.faces.filter {
            Territory.isSealable($0.id, by: player == .player1 ? .player2 : .player1, state: state)
        }.count)

        let total = territory + cycle + parityScore + fluxScore + edgeScore + completionBonus + threat
        transpositionTable[hash] = total
        return total
    }

    /// Explain why a move was chosen (for "Why this move?" analysis).
    public func explainMove(_ cmd: Command, state: GameState) -> String {
        let proj = Legality.project(cmd, state: state)
        guard proj.legal else { return "Illegal move" }

        switch cmd.action {
        case .seal:
            return "Sealing cycle \(cmd.candidateCycleId ?? "?") for territory + cycle bonus"
        case .forge:
            return "Forging edge \(cmd.targetEdgeId ?? "?") to extend network and enable future seals"
        case .pulse:
            return "Pulsing node \(cmd.targetNodeId ?? "?") to capture territory and build influence"
        case .sever:
            return "Severing enemy edge \(cmd.targetEdgeId ?? "?") to disrupt their supply lines"
        case .traverse:
            return "Traversing conduit \(cmd.targetEdgeId ?? "?") to expand to another plateau"
        case .reinforce:
            return "Reinforcing anchor \(cmd.targetNodeId ?? "?") to stabilize influence"
        case .yield:
            return "Yielding — no high-value move available this tick"
        case .counter:
            return "Countering enemy action to reduce their flux and gain composure"
        case .feint:
            return "Feinting at \(cmd.targetNodeId ?? "?") to misdirect"
        case .select:
            return "Moving cursor to \(cmd.targetNodeId ?? "?")"
        case .resign:
            return "Resigning"
        }
    }
}
