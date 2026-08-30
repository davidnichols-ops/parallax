import Foundation
import TacticalCore

/// parallax-cli: deterministic match runner. Plays a full game from a script of
/// commands and prints the result, event-log hash, and per-tick state hashes.
/// Usage: parallax-cli [--board triad|grandmaster] [--seed N] [--max-ticks N]
///                      [--script <path>] [--bot-random]
/// With no script, runs a built-in demo: two scripted players forging links and
/// pulsing toward a decisive score, then a standoff parity demonstration.

struct CLI {
    static func main() {
        let args = ProcessInfo.processInfo.arguments.dropFirst()
        var boardId = "triad"
        var seed: UInt64 = 0xC0FFEE
        var maxTicks = 200
        var scriptPath: String? = nil
        var botRandom = false
        var it = args.makeIterator()
        while let a = it.next() {
            switch a {
            case "--board": boardId = it.next() ?? boardId
            case "--seed": seed = UInt64(it.next() ?? "0") ?? 0
            case "--max-ticks": maxTicks = Int(it.next() ?? "200") ?? 200
            case "--script": scriptPath = it.next()
            case "--bot-random": botRandom = true
            case "--help", "-h":
                print(usage); exit(0)
            default: break
            }
        }

        let board: BoardDefinition
        do {
            switch boardId {
            case "grandmaster": board = BoardFactory.grandmaster()
            default: board = BoardFactory.triad()
            }
            try BoardValidator.validate(board)
        } catch {
            print("Board validation failed: \(error)"); exit(1)
        }

        let commands: [[Command]]
        if let path = scriptPath {
            commands = loadScript(path, board: board)
        } else if botRandom {
            commands = randomBotMatch(board: board, ticks: maxTicks, seed: seed)
        } else {
            commands = demoScript(board: board, ticks: min(maxTicks, 60))
        }

        var engine = Engine(board: board, matchSeed: seed)
        print("Parallax CLI — board=\(board.id) nodes=\(board.nodes.count) edges=\(board.edges.count) faces=\(board.faces.count) seed=\(seed)")
        print("rulesetVersion=\(Balance.version)  ticks=\(commands.count)")
        print(String(repeating: "-", count: 60))

        var tickNo = 0
        for tickCmds in commands {
            if engine.state.gameStatus != .running { break }
            let (snap, events) = engine.submitTick(tickCmds)
            tickNo += 1
            let h = CanonicalEncoding.snapshotHash(snap)
            let p1 = engine.state.playerStates[.player1]!
            let p2 = engine.state.playerStates[.player2]!
            print(String(format: "t=%03d  s1=%3d  s2=%3d  par=%+3d  c1=%2d c2=%2d  flux1=%5d flux2=%5d  evts=%2d  hash=%@",
                         tickNo, p1.score, p2.score, snap.parity,
                         p1.composure, p2.composure, p1.flux, p2.flux,
                         events.count, String(h.prefix(12))))
        }

        print(String(repeating: "-", count: 60))
        let finalSnap = engine.state.snapshot()
        let logHash = CanonicalEncoding.eventLogHash(engine.log)
        switch finalSnap.gameStatus {
        case .ended:
            let reason = finalSnap.endReason.map { String($0.rawValue) } ?? "?"
            if let w = finalSnap.winner {
                print("RESULT: \(w.label) wins — \(reason)")
            } else {
                print("RESULT: draw — \(reason)")
            }
        default:
            print("RESULT: running (max ticks reached)")
        }
        print("moves: P1=\(engine.state.playerStates[.player1]!.moves)  P2=\(engine.state.playerStates[.player2]!.moves)")
        print("events: \(engine.log.events.count)")
        print("eventLogHash: \(logHash)")
        print("finalSnapshotHash: \(CanonicalEncoding.snapshotHash(finalSnap))")

        // Determinism self-check: replay the same commands, compare hashes.
        let replay = Engine.replay(board: board, matchSeed: seed, commands: commands)
        let snapOK = CanonicalEncoding.snapshotHash(replay.snapshot) == CanonicalEncoding.snapshotHash(finalSnap)
        let logOK = replay.logHash == logHash
        let ok = snapOK && logOK
        print("determinismSelfCheck: \(ok ? "PASS" : "FAIL")  [snap=\(snapOK ? "ok" : "FAIL") log=\(logOK ? "ok" : "FAIL")]")
        if !snapOK {
            print("  finalSnapHash: \(CanonicalEncoding.snapshotHash(finalSnap))")
            print("  replaySnapHash: \(CanonicalEncoding.snapshotHash(replay.snapshot))")
        }
        if !ok { exit(2) }
    }

    static let usage = """
    parallax-cli — deterministic Parallax match runner
    Options:
      --board triad|grandmaster   Board family (default: triad)
      --seed N                    Match seed (default: 12648430)
      --max-ticks N               Tick cap (default: 200)
      --script <path>             JSON command script (not implemented in this slice)
      --bot-random                Two random bots play (exercises the engine)
      --help                      This message
    """

    // MARK: scripts

    static func loadScript(_ path: String, board: BoardDefinition) -> [[Command]] {
        // JSON script loading is a later slice; the engine itself is the
        // authority. For now, fall back to the demo.
        print("(script loading not in this slice; running demo)")
        return demoScript(board: board, ticks: 60)
    }

    /// A scripted demo: P1 expands from Alpha(0,0) along row 0 by pulsing each
    /// next node (capturing it), then forges the row edges, then forges downward
    /// to form a face and seals it. P2 mirrors from Alpha(3,3) along row 3.
    /// Demonstrates legality, scoring, territory, and decisive-score ending.
    static func demoScript(board: BoardDefinition, ticks: Int) -> [[Command]] {
        guard board.id == "triad" else {
            return randomBotMatch(board: board, ticks: ticks, seed: 0xDEAD)
        }
        var out: [[Command]] = []
        // Tick 1: select anchors (free).
        out.append([.select(.player1, "p0x0y0"), .select(.player2, "p0x3y3")])
        // P1 pulses rightward along row 0: (1,0), (2,0), (3,0).
        // P2 pulses leftward along row 3: (2,3), (1,3), (0,3).
        // Each pulse captures the neutral node (influence -> 100, owner -> player).
        let p1Pulses = ["p0x1y0", "p0x2y0", "p0x3y0"]
        let p2Pulses = ["p0x2y3", "p0x1y3", "p0x0y3"]
        for i in 0..<3 {
            out.append([.pulse(.player1, p1Pulses[i]), .pulse(.player2, p2Pulses[i])])
        }
        // Now forge the row edges (both endpoints owned).
        let p1RowEdges = ["p0x0y0--p0x1y0", "p0x1y0--p0x2y0", "p0x2y0--p0x3y0"]
        let p2RowEdges = ["p0x0y3--p0x1y3", "p0x1y3--p0x2y3", "p0x2y3--p0x3y3"]
        for i in 0..<3 {
            out.append([.forge(.player1, p1RowEdges[i]), .forge(.player2, p2RowEdges[i])])
        }
        // Pulse downward to capture column nodes for face-building.
        // P1: capture (0,1),(1,1) then forge (0,0)-(0,1),(1,0)-(1,1),(0,1)-(1,1) -> seal F_p0_x0_y0.
        // P2: capture (3,2),(2,2) then forge (3,3)-(3,2),(2,3)-(2,2),(3,2)-(2,2) -> seal F_p0_x2_y2.
        out.append([.pulse(.player1, "p0x0y1"), .pulse(.player2, "p0x3y2")])
        out.append([.pulse(.player1, "p0x1y1"), .pulse(.player2, "p0x2y2")])
        out.append([.forge(.player1, "p0x0y0--p0x0y1"), .forge(.player2, "p0x3y3--p0x3y2")])
        out.append([.forge(.player1, "p0x1y0--p0x1y1"), .forge(.player2, "p0x2y3--p0x2y2")])
        out.append([.forge(.player1, "p0x0y1--p0x1y1"), .forge(.player2, "p0x3y2--p0x2y2")])
        // Seal the first face each — this grants territory + cycle bonus.
        out.append([.seal(.player1, "F_p0_x0_y0"), .seal(.player2, "F_p0_x2_y2")])
        // Continue expanding: build a second face each and seal it.
        // P1: capture (0,2),(1,2); forge (0,1)-(0,2),(1,1)-(1,2),(0,2)-(1,2); seal F_p0_x0_y1.
        // P2: capture (3,1),(2,1); forge (3,2)-(3,1),(2,2)-(2,1),(3,1)-(2,1); seal F_p0_x2_y1.
        out.append([.pulse(.player1, "p0x0y2"), .pulse(.player2, "p0x3y1")])
        out.append([.pulse(.player1, "p0x1y2"), .pulse(.player2, "p0x2y1")])
        out.append([.forge(.player1, "p0x0y1--p0x0y2"), .forge(.player2, "p0x3y2--p0x3y1")])
        out.append([.forge(.player1, "p0x1y1--p0x1y2"), .forge(.player2, "p0x2y2--p0x2y1")])
        out.append([.forge(.player1, "p0x0y2--p0x1y2"), .forge(.player2, "p0x3y1--p0x2y1")])
        out.append([.seal(.player1, "F_p0_x0_y1"), .seal(.player2, "F_p0_x2_y1")])
        // Fill remaining ticks with yields (no-op) to let the match settle.
        while out.count < ticks {
            out.append([.yield_(.player1), .yield_(.player2)])
        }
        return out
    }

    /// Two random bots: each tick, each bot picks a random legal command from a
    /// small candidate set. Exercises the full engine + determinism.
    static func randomBotMatch(board: BoardDefinition, ticks: Int, seed: UInt64) -> [[Command]] {
        var rng = SeededRNG(seed: seed)
        // Build a fresh engine to probe legality each tick.
        var probe = Engine(board: board, matchSeed: seed)
        var out: [[Command]] = []
        for _ in 0..<ticks {
            if probe.state.gameStatus != .running { break }
            var tickCmds: [Command] = []
            for p in [Player.player1, .player2] {
                let cmd = pickRandomLegal(p, state: probe.state, rng: &rng)
                tickCmds.append(cmd)
            }
            // Apply to probe to keep legality in sync.
            probe.submitTick(tickCmds)
            out.append(tickCmds)
        }
        return out
    }

    static func pickRandomLegal(_ player: Player, state: GameState, rng: inout SeededRNG) -> Command {
        // Candidate set: select a random node, forge a random intra edge from
        // owned nodes, pulse a random adjacent node, or yield.
        let ownedNodes = state.board.nodes.filter { state.nodes[$0.id]?.owner == player.owner }
        if ownedNodes.isEmpty { return .yield_(player) }
        let pick = rng.uniform(lessThan: 4)
        if pick == 0 {
            let n = ownedNodes[rng.uniform(lessThan: ownedNodes.count)]
            return .select(player, n.id)
        }
        // Forge: find intra edges where one endpoint owned by player, other neutral/player.
        let candidates = state.board.edges.filter { def in
            guard def.kind == .intra else { return false }
            if let es = state.edges[def.id], es.severed { return false }
            let u = state.nodes[def.u]?.owner ?? .neutral
            let v = state.nodes[def.v]?.owner ?? .neutral
            return (u == player.owner && (v == player.owner || v == .neutral))
                || (v == player.owner && (u == player.owner || u == .neutral))
        }
        if pick == 1, !candidates.isEmpty {
            let e = candidates[rng.uniform(lessThan: candidates.count)]
            return .forge(player, e.id)
        }
        // Pulse: pick an owned node with influence>=40, pulse an adjacent node.
        let strong = ownedNodes.filter { (state.nodes[$0.id]?.influence ?? 0) >= 40 }
        if pick == 2, !strong.isEmpty {
            let src = strong[rng.uniform(lessThan: strong.count)]
            let adj = (state.board.incidence[src.id] ?? []).compactMap { eid -> String? in
                let def = state.board.edgeMap[eid]!
                if def.kind != .intra { return nil }
                if let es = state.edges[eid], es.severed { return nil }
                return def.u == src.id ? def.v : (def.v == src.id ? def.u : nil)
            }
            if !adj.isEmpty {
                return .pulse(player, adj[rng.uniform(lessThan: adj.count)])
            }
        }
        return .yield_(player)
    }
}

CLI.main()
