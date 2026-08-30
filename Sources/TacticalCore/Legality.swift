import Foundation

/// Legality and pre-commitment projection (rulebook §9). Pure functions; the
/// authority re-checks on submission.
public enum Legality {

    /// Normalize an edge identifier to canonical sorted form "a--b" where a <= b.
    /// Accepts either endpoint order, or a pre-canonicalized id.
    public static func canonicalEdgeId(_ id: String) -> String {
        let parts = id.components(separatedBy: "--")
        guard parts.count == 2 else { return id }
        let sorted = parts.sorted()
        return sorted[0] + "--" + sorted[1]
    }

    /// Normalize a command's edge target to canonical form.
    public static func normalize(_ cmd: Command) -> Command {
        var c = cmd
        if let eid = c.targetEdgeId {
            c = Command(player: c.player, action: c.action,
                        targetNodeId: c.targetNodeId,
                        targetEdgeId: canonicalEdgeId(eid),
                        candidateCycleId: c.candidateCycleId,
                        counteredSeq: c.counteredSeq, targetTick: c.targetTick)
        }
        return c
    }

    public static func project(_ cmd: Command, state: GameState) -> Projection {
        let cmd = normalize(cmd)
        guard state.gameStatus == .running else {
            return Projection(legal: false, cost: 0, reason: .gameNotRunning)
        }
        switch cmd.action {
        case .select:
            return projectSelect(cmd, state)
        case .pulse:
            return projectPulse(cmd, state)
        case .forge:
            return projectForge(cmd, state)
        case .traverse:
            return projectTraverse(cmd, state)
        case .counter:
            return projectCounter(cmd, state)
        case .sever:
            return projectSever(cmd, state)
        case .seal:
            return projectSeal(cmd, state)
        case .reinforce:
            return projectReinforce(cmd, state)
        case .feint:
            return projectFeint(cmd, state)
        case .yield:
            return Projection(legal: true, cost: Balance.costYield, reason: nil)
        case .resign:
            return Projection(legal: true, cost: 0, reason: nil)
        }
    }

    // MARK: per-action

    static func projectSelect(_ cmd: Command, _ s: GameState) -> Projection {
        guard let id = cmd.targetNodeId, s.board.nodeMap[id] != nil else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        return Projection(legal: true, cost: Balance.costSelect, reason: nil)
    }

    static func projectPulse(_ cmd: Command, _ s: GameState) -> Projection {
        guard let id = cmd.targetNodeId, let target = s.board.nodeMap[id] else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costPulse
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        // Target must be adjacent (intra edge) to a node owned by p with influence>=40,
        // OR adjacent to the player's cursor node via a non-severed intra edge.
        let cursorId = cursorNodeId(s, p)
        var ok = false
        for eid in s.board.incidence[id] ?? [] {
            let def = s.board.edgeMap[eid]!
            if def.kind != .intra { continue }
            if let es = s.edges[eid], es.severed { continue }
            let other = def.u == id ? def.v : def.u
            if other == cursorId { ok = true; break }
            if let ns = s.nodes[other], ns.owner == p.owner, ns.influence >= 40 { ok = true; break }
        }
        if !ok { return Projection(legal: false, cost: cost, reason: .notAdjacent) }
        _ = target
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectForge(_ cmd: Command, _ s: GameState) -> Projection {
        guard let eid = cmd.targetEdgeId, let def = s.board.edgeMap[eid] else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costForge
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        if def.kind != .intra { return Projection(legal: false, cost: cost, reason: .illegalAction) }
        if let es = s.edges[eid], es.severed { return Projection(legal: false, cost: cost, reason: .edgeSevered) }
        let uOwner = s.nodes[def.u]?.owner ?? .neutral
        let vOwner = s.nodes[def.v]?.owner ?? .neutral
        // u owned by p, v owned by p or neutral.
        if uOwner != p.owner { return Projection(legal: false, cost: cost, reason: .notOwnedByPlayer) }
        if vOwner != p.owner && vOwner != .neutral {
            return Projection(legal: false, cost: cost, reason: .notOwnedByPlayer)
        }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectTraverse(_ cmd: Command, _ s: GameState) -> Projection {
        guard let eid = cmd.targetEdgeId, let def = s.board.edgeMap[eid] else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        if def.kind != .conduit {
            return Projection(legal: false, cost: 0, reason: .illegalAction)
        }
        let cost = Balance.traverseCost(capacity: def.capacity)
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        if let es = s.edges[eid], es.severed { return Projection(legal: false, cost: cost, reason: .edgeSevered) }
        // Source endpoint owned by p.
        let uOwner = s.nodes[def.u]?.owner ?? .neutral
        let vOwner = s.nodes[def.v]?.owner ?? .neutral
        let sourceOwned = (uOwner == p.owner) || (vOwner == p.owner)
        if !sourceOwned { return Projection(legal: false, cost: cost, reason: .notOwnedByPlayer) }
        // Occluded if neither endpoint owned by p and severed (already checked severed).
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectCounter(_ cmd: Command, _ s: GameState) -> Projection {
        guard let eid = cmd.targetEdgeId, let _ = s.board.edgeMap[eid] else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costCounter
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        guard let es = s.edges[eid] else {
            return Projection(legal: false, cost: cost, reason: .invalidTarget)
        }
        if es.owner != p.opponent.owner {
            return Projection(legal: false, cost: cost, reason: .notEnemyOwned)
        }
        // Counter window: the countered seq must be from the previous tick.
        guard let seq = cmd.counteredSeq else {
            return Projection(legal: false, cost: cost, reason: .counterWindowExpired)
        }
        let found = s.lastCounterableActions.contains { $0.seq == seq && $0.player == p.opponent }
        if !found { return Projection(legal: false, cost: cost, reason: .counterWindowExpired) }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectSever(_ cmd: Command, _ s: GameState) -> Projection {
        guard let eid = cmd.targetEdgeId, s.board.edgeMap[eid] != nil else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costSever
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        guard let es = s.edges[eid] else {
            return Projection(legal: false, cost: cost, reason: .invalidTarget)
        }
        if es.owner != p.opponent.owner && es.owner != .severed {
            return Projection(legal: false, cost: cost, reason: .notEnemyOwned)
        }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectSeal(_ cmd: Command, _ s: GameState) -> Projection {
        guard let fid = cmd.candidateCycleId else {
            return Projection(legal: false, cost: 0, reason: .noCandidateCycle)
        }
        let p = cmd.player
        let cost = Balance.costSeal
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        if !Territory.isSealable(fid, by: p, state: s) {
            // Distinguish already-sealed vs not-yet.
            if s.faces[fid]?.sealedBy == p.owner {
                return Projection(legal: false, cost: cost, reason: .cycleAlreadySealed)
            }
            return Projection(legal: false, cost: cost, reason: .noCandidateCycle)
        }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectReinforce(_ cmd: Command, _ s: GameState) -> Projection {
        guard let id = cmd.targetNodeId, let def = s.board.nodeMap[id] else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costReinforce
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        let ns = s.nodes[id]
        let isAnchor = (def.kind == .anchor)
        let isOwnedFull = (ns?.owner == p.owner && ns?.influence == 100)
        if !(isAnchor && ns?.owner == p.owner) && !isOwnedFull {
            return Projection(legal: false, cost: cost, reason: .notAnAnchor)
        }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    static func projectFeint(_ cmd: Command, _ s: GameState) -> Projection {
        guard let id = cmd.targetNodeId, s.board.nodeMap[id] != nil else {
            return Projection(legal: false, cost: 0, reason: .invalidTarget)
        }
        let p = cmd.player
        let cost = Balance.costFeint
        if flux(s, p) < cost { return Projection(legal: false, cost: cost, reason: .insufficientFlux) }
        // Target must be adjacent to cursor.
        let cursorId = cursorNodeId(s, p)
        let adj = (s.board.incidence[id] ?? []).contains { eid in
            let def = s.board.edgeMap[eid]!
            let other = def.u == id ? def.v : def.u
            return other == cursorId
        }
        if !adj { return Projection(legal: false, cost: cost, reason: .notAdjacent) }
        return Projection(legal: true, cost: cost, reason: nil)
    }

    // MARK: helpers

    static func flux(_ s: GameState, _ p: Player) -> Int {
        s.playerStates[p]?.flux ?? 0
    }
    public static func cursorNodeId(_ s: GameState, _ p: Player) -> String {
        let ps = s.playerStates[p]!
        return BoardFactory.nid(ps.cursorPlateau, ps.cursorX, ps.cursorY)
    }
}
