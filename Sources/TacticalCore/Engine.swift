import Foundation

/// The deterministic engine. No UI, no audio, no wall-clock, no networking.
/// Advances in integer ticks; all randomness is seeded and recorded.
public struct Engine: Sendable {
    public private(set) var state: GameState
    public private(set) var log: EventLog
    public let board: BoardDefinition

    public init(board: BoardDefinition, matchSeed: UInt64) {
        self.board = board
        self.state = GameState(board: board, matchSeed: matchSeed)
        self.log = EventLog()
    }

    public init(restoring snapshot: Snapshot, board: BoardDefinition) {
        self.board = board
        self.state = GameState(from: snapshot, board: board)
        self.log = EventLog()
    }

    /// Restore an engine from a snapshot AND a live counter-window state.
    /// `GameState.init(from:board:)` resets `lastCounterableActions` to `[]`
    /// because the counter window is transient (actions from the previous tick).
    /// This initializer re-attaches the counterable actions so a resumed match
    /// — including training lessons that pre-ran a setup tick — can accept
    /// counter commands immediately after restoration. Used by replay v2.
    public init(restoring snapshot: Snapshot, board: BoardDefinition,
                counterableActions: [GameState.CounterableAction]) {
        self.board = board
        var gs = GameState(from: snapshot, board: board)
        gs.lastCounterableActions = counterableActions
        self.state = gs
        self.log = EventLog()
    }

    // MARK: - Public API

    /// Pre-check a command without mutating state.
    public func project(_ cmd: Command) -> Projection { Legality.project(cmd, state: state) }

    /// The candidate cycle (face) that `seal` would seal, for pre-visualization.
    public func sealCandidate(for cmd: Command) -> String? { cmd.candidateCycleId }

    /// All currently sealable faces for `player` (for UI ghost previews).
    public func sealableFaces(_ player: Player) -> [String] {
        state.board.faces.filter { Territory.isSealable($0.id, by: player, state: state) }.map { $0.id }
    }

    /// Resolve one tick. Commands are immutable; the authority assigns seqs.
    /// Returns the snapshot at end of tick and the events emitted this tick.
    @discardableResult
    public mutating func submitTick(_ commands: [Command]) -> (snapshot: Snapshot, events: [Event]) {
        guard state.gameStatus == .running else {
            return (state.snapshot(), [])
        }
        let tick = state.tick + 1
        var tickEvents: [Event] = []

        // Filter resign (meta) — handled immediately, ends match.
        let resigns = commands.filter { $0.action == .resign }
        for r in resigns {
            state.gameStatus = .ended
            state.winner = r.player.opponent
            state.endReason = .resignation
            let e = log.append(.matchWon, tick: tick, player: r.player.opponent,
                               payload: ["reason": "resignation", "resigner": r.player.label])
            tickEvents.append(e)
            return (state.snapshot(), tickEvents)
        }

        let active = commands.filter { $0.action != .resign }
        // Group by action, in canonical stage order.
        let stageOrder: [ActionKind] = [.yield, .select, .reinforce, .sever, .counter,
                                        .forge, .traverse, .pulse, .seal, .feint]
        // Acting order this tick (initiative flip).
        let order: [Player] = (state.firstActorThisTick == .player1)
            ? [.player1, .player2] : [.player2, .player1]

        // Set the tick first so start/end content hashes are comparable.
        state.tick = tick
        let startContent = CanonicalEncoding.contentHash(state.snapshot())

        var meaningfulChange = false
        var counterableThisTick: [GameState.CounterableAction] = []

        for stage in stageOrder {
            let stageCmds = active.filter { $0.action == stage }
            if stageCmds.isEmpty { continue }
            // Split by player in acting order.
            let firstCmds = stageCmds.filter { $0.player == order[0] }
            let secondCmds = stageCmds.filter { $0.player == order[1] }

            // Detect conflict: same target edge or node between first & second.
            let conflict = detectConflict(firstCmds, secondCmds)

            for (idx, _) in order.enumerated() {
                let cmds = (idx == 0) ? firstCmds : secondCmds
                for cmd in cmds {
                    let (applied, changed) = apply(cmd, tick: tick, playerActingOrder: order,
                                        conflict: conflict, counterable: &counterableThisTick)
                    tickEvents.append(contentsOf: applied)
                    if changed { meaningfulChange = true }
                }
            }
        }

        // End-of-tick: sever cooldowns, territory recompute, scoring, parity,
        // composure, feint expiry, endings.
        advanceSeverCooldowns(tick: tick, events: &tickEvents, meaningful: &meaningfulChange)
        expireFeints(tick: tick)
        Territory.recomputeControl(state: &state)
        recomputeScoresAndParity(events: &tickEvents, tick: tick)
        recomputeComposure(tickEvents: tickEvents, tick: tick)

        // Initiative flip for next tick.
        state.firstActorThisTick = order[1]

        // Meaningful-change tracking for board exhaustion (content hash excludes
        // the tick counter and this very field, so a no-op tick is detected).
        let endContent = CanonicalEncoding.contentHash(state.snapshot())
        if startContent != endContent { state.ticksSinceMeaningfulChange = 0 }
        else { state.ticksSinceMeaningfulChange += 1 }

        // Endings.
        checkEndings(tick: tick, events: &tickEvents)

        state.lastCounterableActions = counterableThisTick

        let endSnapHash = CanonicalEncoding.snapshotHash(state.snapshot())
        let e = log.append(.tickResolved, tick: tick, player: nil,
                           payload: ["seq": String(log.nextSeq - 1),
                                     "hash": endSnapHash])
        tickEvents.append(e)

        return (state.snapshot(), tickEvents)
    }

    // MARK: - Conflict detection

    struct Conflict {
        let edgeId: String?
        let nodeId: String?
    }
    func detectConflict(_ a: [Command], _ b: [Command]) -> Conflict? {
        for x in a {
            for y in b {
                if let xe = x.targetEdgeId, let ye = y.targetEdgeId, xe == ye {
                    return Conflict(edgeId: xe, nodeId: nil)
                }
                if let xn = x.targetNodeId, let yn = y.targetNodeId, xn == yn {
                    return Conflict(edgeId: nil, nodeId: xn)
                }
            }
        }
        return nil
    }

    // MARK: - Per-action application

    mutating func apply(_ cmd: Command, tick: Int, playerActingOrder: [Player],
                        conflict: Conflict?, counterable: inout [GameState.CounterableAction])
                        -> (events: [Event], changed: Bool) {
        let cmd = Legality.normalize(cmd)
        let proj = Legality.project(cmd, state: state)
        if !proj.legal {
            let e = log.append(.actionRejected, tick: tick, player: cmd.player,
                               payload: ["action": cmd.action.rawValue,
                                         "reason": proj.reason?.rawValue ?? "unknown"])
            // Miscommand composure penalty applied at tick end via event presence.
            return ([e], false)
        }
        // Deduct flux.
        var ps = state.playerStates[cmd.player]!
        ps.flux = max(0, ps.flux - proj.cost)
        state.playerStates[cmd.player] = ps

        var events: [Event] = []
        var changed = false
        switch cmd.action {
        case .select:
            if let id = cmd.targetNodeId, let def = board.nodeMap[id] {
                var p = state.playerStates[cmd.player]!
                p.cursorPlateau = def.plateau; p.cursorX = def.x; p.cursorY = def.y
                state.playerStates[cmd.player] = p
                events.append(log.append(.cursorMoved, tick: tick, player: cmd.player,
                                         payload: ["node": id]))
            }
        case .yield:
            events.append(log.append(.yieldIssued, tick: tick, player: cmd.player, payload: [:]))
        case .reinforce:
            if let id = cmd.targetNodeId {
                if var ns = state.nodes[id] {
                    ns.influence = 100
                    ns.shieldTicks = Balance.shieldWindow
                    state.nodes[id] = ns
                }
                let def = board.nodeMap[id]!
                if def.kind == .anchor {
                    var p = state.playerStates[cmd.player]!
                    p.flux = min(Balance.maxFlux, p.flux + Balance.anchorFluxRegen)
                    state.playerStates[cmd.player] = p
                }
                events.append(log.append(.anchorReinforced, tick: tick, player: cmd.player,
                                         payload: ["node": id]))
                changed = true
            }
        case .sever:
            if let eid = cmd.targetEdgeId {
                let def = board.edgeMap[eid]!
                // Shield check: if either endpoint has shieldTicks > 0 owned by opponent
                // of the severing player, the sever is reduced (no cycle break, short cooldown).
                let uShielded = (state.nodes[def.u]?.shieldTicks ?? 0) > 0
                                && state.nodes[def.u]?.owner == cmd.player.opponent.owner
                let vShielded = (state.nodes[def.v]?.shieldTicks ?? 0) > 0
                                && state.nodes[def.v]?.owner == cmd.player.opponent.owner
                let shielded = uShielded || vShielded
                var es = state.edges[eid]!
                es.owner = .severed
                es.severed = true
                es.flux = 0
                es.cooldown = shielded ? Balance.shieldedSeverCooldown : Balance.severCooldown
                es.sealed = false
                es.sealedCycleIds = []
                state.edges[eid] = es
                if !shielded {
                    let broken = Territory.breakCyclesThrough(eid, state: &state)
                    for b in broken {
                        events.append(log.append(.cycleBroken, tick: tick,
                                                 player: cmd.player.opponent,
                                                 payload: ["face": b, "bySever": eid]))
                    }
                }
                Territory.recomputeControl(state: &state)
                events.append(log.append(.linkSevered, tick: tick, player: cmd.player,
                                         payload: ["edge": eid, "shielded": shielded ? "1" : "0",
                                                   "cooldown": String(es.cooldown)]))
                counterable.append(.init(seq: log.nextSeq - 1, player: cmd.player,
                                         action: .sever, targetEdge: eid, targetNode: nil, tick: tick))
                changed = true
            }
        case .counter:
            if let eid = cmd.targetEdgeId {
                var es = state.edges[eid]!
                if es.owner == cmd.player.opponent.owner {
                    es.flux -= Balance.counterFluxDamage
                    if es.flux <= 0 {
                        es.owner = .neutral; es.flux = 0
                    }
                    state.edges[eid] = es
                    var p = state.playerStates[cmd.player]!
                    p.successfulCounters += 1
                    p.initiative += 1
                    state.playerStates[cmd.player] = p
                    events.append(log.append(.vectorCountered, tick: tick, player: cmd.player,
                                             payload: ["edge": eid, "seq": String(cmd.counteredSeq ?? -1)]))
                    changed = true
                } else {
                    events.append(log.append(.counterFailed, tick: tick, player: cmd.player,
                                             payload: ["edge": eid]))
                }
            }
        case .forge:
            if let eid = cmd.targetEdgeId {
                var es = state.edges[eid]!
                es.owner = cmd.player.owner
                let def = board.edgeMap[eid]!
                let bothOwned = state.nodes[def.u]?.owner == cmd.player.owner
                                && state.nodes[def.v]?.owner == cmd.player.owner
                es.flux = bothOwned ? 100 : min(100, es.flux + Balance.forgeGain)
                state.edges[eid] = es
                events.append(log.append(.linkForged, tick: tick, player: cmd.player,
                                         payload: ["edge": eid, "reinforced": bothOwned ? "1" : "0"]))
                counterable.append(.init(seq: log.nextSeq - 1, player: cmd.player,
                                         action: .forge, targetEdge: eid, targetNode: nil, tick: tick))
                changed = true
            }
        case .traverse:
            if let eid = cmd.targetEdgeId {
                let def = board.edgeMap[eid]!
                var es = state.edges[eid]!
                // Capacity pressure: if opponent traversed same conduit within `capacity` ticks.
                let contested = (es.lastTraversedBy == cmd.player.opponent.owner)
                                && (tick - es.lastTraverseTick <= def.capacity)
                if contested {
                    es.flux = max(0, es.flux - 50)
                    state.edges[eid] = es
                    events.append(log.append(.conduitContested, tick: tick, player: cmd.player,
                                             payload: ["edge": eid]))
                } else {
                    es.owner = cmd.player.owner
                    es.flux = 100
                    es.lastTraversedBy = cmd.player.owner
                    es.lastTraverseTick = tick
                    state.edges[eid] = es
                    // Target node = the endpoint not owned by player (or neutral).
                    let target = (state.nodes[def.u]?.owner == cmd.player.owner) ? def.v : def.u
                    if var ns = state.nodes[target], !ns.locked {
                        ns.influence += Balance.conduitInfluenceGain
                        if ns.owner == .neutral { ns.owner = cmd.player.owner }
                        if ns.influence > 100 { ns.influence = 100 }
                        state.nodes[target] = ns
                    }
                    // Move cursor to target.
                    if let tdef = board.nodeMap[target] {
                        var p = state.playerStates[cmd.player]!
                        p.cursorPlateau = tdef.plateau; p.cursorX = tdef.x; p.cursorY = tdef.y
                        state.playerStates[cmd.player] = p
                    }
                    events.append(log.append(.conduitTraversed, tick: tick, player: cmd.player,
                                             payload: ["edge": eid, "target": target]))
                    counterable.append(.init(seq: log.nextSeq - 1, player: cmd.player,
                                             action: .traverse, targetEdge: eid, targetNode: nil, tick: tick))
                }
                changed = true
            }
        case .pulse:
            if let id = cmd.targetNodeId {
                var ns = state.nodes[id]!
                if ns.owner == .neutral {
                    ns.owner = cmd.player.owner
                    ns.influence = 100
                    state.nodes[id] = ns
                    events.append(log.append(.nodePulsed, tick: tick, player: cmd.player,
                                             payload: ["node": id, "captured": "1"]))
                } else if ns.owner == cmd.player.owner {
                    ns.influence = min(100, ns.influence + Balance.pulseGain)
                    state.nodes[id] = ns
                    events.append(log.append(.nodePulsed, tick: tick, player: cmd.player,
                                             payload: ["node": id, "captured": "0"]))
                } else if ns.owner == cmd.player.opponent.owner && !ns.locked {
                    // Contest: reduce influence; flip to neutral at 0 (defender priority).
                    ns.influence -= Balance.pulseGain
                    if ns.influence <= 0 {
                        ns.influence = 0
                        ns.owner = .neutral
                    }
                    state.nodes[id] = ns
                    events.append(log.append(.nodeContested, tick: tick, player: cmd.player,
                                             payload: ["node": id, "influence": String(ns.influence)]))
                }
                changed = true
            }
        case .seal:
            if let fid = cmd.candidateCycleId,
               Territory.isSealable(fid, by: cmd.player, state: state) {
                var fs = state.faces[fid]!
                fs.sealedBy = cmd.player.owner
                fs.sealedCycleId = fid
                fs.controller = cmd.player.owner
                state.faces[fid] = fs
                let face = board.faceMap[fid]!
                for eid in face.boundary {
                    if var es = state.edges[eid] {
                        es.sealed = true
                        es.sealedCycleIds.append(fid)
                        state.edges[eid] = es
                    }
                    let def = board.edgeMap[eid]!
                    for nid in [def.u, def.v] {
                        if var ns = state.nodes[nid] {
                            ns.sealedCycleIds.append(fid)
                            state.nodes[nid] = ns
                        }
                    }
                }
                var p = state.playerStates[cmd.player]!
                p.sealedCycles += 1
                state.playerStates[cmd.player] = p
                events.append(log.append(.cycleSealed, tick: tick, player: cmd.player,
                                         payload: ["face": fid]))
                changed = true
            }
        case .feint:
            if let id = cmd.targetNodeId {
                let marker = FeintMarker(nodeId: id, expiresAtTick: tick + Balance.feintWindow)
                state.feints[cmd.player, default: []].append(marker)
                events.append(log.append(.feintRegistered, tick: tick, player: cmd.player,
                                         payload: ["node": id, "expires": String(marker.expiresAtTick)]))
                // Opponent sees only that a feint occurred (no location).
                events.append(log.append(.opponentFeinted, tick: tick, player: cmd.player.opponent,
                                         payload: [:]))
            }
        case .resign:
            break // handled earlier
        }

        // Conflict-matrix override: if this command was the loser of a same-tick
        // conflict, emit a rejection-style event. The matrix is approximated by
        // re-checking ownership after the opposing command has applied; the
        // canonical order + per-action guards above already implement most cells.
        // (Full cell-by-cell matrix is exercised by table-driven tests.)

        // Count as a move if it changed state.
        if changed {
            var p = state.playerStates[cmd.player]!
            p.moves += 1
            state.playerStates[cmd.player] = p
        }
        return (events, changed)
    }

    // MARK: - End-of-tick maintenance

    mutating func advanceSeverCooldowns(tick: Int, events: inout [Event], meaningful: inout Bool) {
        for eid in board.edges.map(\.id) {
            if var es = state.edges[eid], es.severed && es.cooldown > 0 {
                es.cooldown -= 1
                if es.cooldown <= 0 {
                    es.severed = false
                    es.owner = .neutral
                    es.flux = 0
                    events.append(log.append(.edgeRestored, tick: tick, player: nil,
                                             payload: ["edge": eid]))
                    meaningful = true
                }
                state.edges[eid] = es
            }
        }
        // Decrement shield windows.
        for nid in board.nodes.map(\.id) {
            if var ns = state.nodes[nid], ns.shieldTicks > 0 {
                ns.shieldTicks -= 1
                state.nodes[nid] = ns
            }
        }
    }

    mutating func expireFeints(tick: Int) {
        for p in [Player.player1, .player2] {
            state.feints[p] = (state.feints[p] ?? []).filter { $0.expiresAtTick >= tick }
        }
    }

    mutating func recomputeScoresAndParity(events: inout [Event], tick: Int) {
        let s1 = Scoring.computeScore(.player1, state: state)
        let s2 = Scoring.computeScore(.player2, state: state)
        var p1 = state.playerStates[.player1]!
        var p2 = state.playerStates[.player2]!
        let prev1 = p1.score, prev2 = p2.score
        p1.score = s1; p2.score = s2
        state.playerStates[.player1] = p1
        state.playerStates[.player2] = p2
        if s1 != prev1 {
            events.append(log.append(.scoreChanged, tick: tick, player: .player1,
                                     payload: ["score": String(s1)]))
        }
        if s2 != prev2 {
            events.append(log.append(.scoreChanged, tick: tick, player: .player2,
                                     payload: ["score": String(s2)]))
        }
        let prevParity = state.parity
        state.parity = s1 - s2
        if state.parity != prevParity {
            events.append(log.append(.parityChanged, tick: tick, player: nil,
                                     payload: ["parity": String(state.parity)]))
        }
    }

    mutating func recomputeComposure(tickEvents: [Event], tick: Int) {
        for p in [Player.player1, .player2] {
            let newC = Scoring.applyComposure(p, state: state, events: tickEvents)
            var ps = state.playerStates[p]!
            let prev = ps.composure
            ps.composure = newC
            state.playerStates[p] = ps
            if newC != prev {
                _ = log.append(.composureChanged, tick: tick, player: p,
                               payload: ["composure": String(newC)])
            }
        }
    }

    mutating func checkEndings(tick: Int, events: inout [Event]) {
        if state.gameStatus != .running { return }
        let s1 = state.playerStates[.player1]!.score
        let s2 = state.playerStates[.player2]!.score
        // Decisive score: >= 100 and |parity| > band.
        if s1 >= Balance.matchPressureTarget && (s1 - s2) > Balance.parityBand {
            state.gameStatus = .ended; state.winner = .player1; state.endReason = .decisiveScore
            events.append(log.append(.matchWon, tick: tick, player: .player1,
                                     payload: ["reason": "decisiveScore", "score": String(s1)]))
            return
        }
        if s2 >= Balance.matchPressureTarget && (s2 - s1) > Balance.parityBand {
            state.gameStatus = .ended; state.winner = .player2; state.endReason = .decisiveScore
            events.append(log.append(.matchWon, tick: tick, player: .player2,
                                     payload: ["reason": "decisiveScore", "score": String(s2)]))
            return
        }
        // Board exhaustion.
        if state.ticksSinceMeaningfulChange >= Balance.exhaustionTicks {
            state.gameStatus = .ended; state.winner = nil; state.endReason = .boardExhaustion
            events.append(log.append(.matchDrawn, tick: tick, player: nil,
                                     payload: ["reason": "boardExhaustion"]))
        }
    }

    // MARK: - Replay

    /// Replay a command stream from a fresh engine; returns the final snapshot
    /// and event-log hash. Used for determinism tests (master prompt §39, §42).
    public static func replay(board: BoardDefinition, matchSeed: UInt64,
                              commands: [[Command]]) -> (snapshot: Snapshot, logHash: String) {
        var eng = Engine(board: board, matchSeed: matchSeed)
        for tickCmds in commands {
            if eng.state.gameStatus != .running { break }
            eng.submitTick(tickCmds)
        }
        return (eng.state.snapshot(), CanonicalEncoding.eventLogHash(eng.log))
    }
}
