import Foundation
import TacticalCore
import TacticalBots
import TacticalPersistence

/// parallax-tools — developer CLI for bot benchmarks, board validation, and
/// replay verification. Not shipped in the release app.
@main
struct ParallaxTools {
    static func main() {
        let args = CommandLine.arguments

        if args.count < 2 {
            printUsage()
            return
        }

        switch args[1] {
        case "benchmark":
            runBenchmark()
        case "bot-vs-bot":
            runBotVsBot(args)
        case "bot-vs-random":
            runBotVsRandom(args)
        case "validate-board":
            validateBoard(args)
        case "export-board":
            exportBoard(args)
        case "verify-replay":
            verifyReplay(args)
        case "--help", "-h":
            printUsage()
        default:
            print("Unknown command: \(args[1])")
            printUsage()
        }
    }

    static func printUsage() {
        print("""
        parallax-tools — developer CLI

        Commands:
          benchmark              Run full bot benchmark suite (GM vs random, GM vs novice)
          bot-vs-bot             Run grandmaster vs grandmaster match
          bot-vs-random          Run grandmaster vs random baseline
          validate-board <id>    Validate board topology
          export-board <id>      Export board definition as JSON
          verify-replay <file>   Verify replay integrity

        Options:
          --ticks <N>            Max ticks (default 200)
          --seed <N>             Match seed (default 12345)
          --difficulty <level>   Bot difficulty: novice|adept|master|grandmaster
          --personality <type>   Bot personality: aggressive|defensive|balanced|standoff
        """)
    }

    static func runBenchmark() {
        print("=== Bot Benchmark Suite ===")
        let bench = BotBenchmark(maxTicks: 200)

        print("\n1. Grandmaster vs Random (10 trials)...")
        var gmWins = 0
        for i in 0..<10 {
            let r = bench.runBotVsRandom(
                botDifficulty: .grandmaster, botPersonality: .aggressive,
                botPlayer: .player1, seed: UInt64(i * 1000)
            )
            let win = r.winner == .player1 || (r.winner == nil && r.p1Score > r.p2Score)
            if win { gmWins += 1 }
            print("  Trial \(i): P1=\(r.p1Score) P2=\(r.p2Score) ticks=\(r.ticks) winner=\(r.winner?.label ?? "draw") \(win ? "WIN" : "LOSS")")
        }
        print("  Grandmaster win rate: \(gmWins)/10 (\(gmWins * 10)%)")
        print("  PASS: \(gmWins >= 8 ? "YES" : "NO")")

        print("\n2. Grandmaster vs Novice (10 trials)...")
        var gmVsNoviceWins = 0
        for i in 0..<10 {
            let r = bench.runBotVsBot(
                p1Difficulty: .grandmaster, p1Personality: .aggressive,
                p2Difficulty: .novice, p2Personality: .balanced,
                seed: UInt64(i * 1000)
            )
            let win = r.winner == .player1 || (r.winner == nil && r.p1Score > r.p2Score)
            if win { gmVsNoviceWins += 1 }
            print("  Trial \(i): P1=\(r.p1Score) P2=\(r.p2Score) ticks=\(r.ticks) winner=\(r.winner?.label ?? "draw") \(win ? "WIN" : "LOSS")")
        }
        print("  Grandmaster win rate vs novice: \(gmVsNoviceWins)/10 (\(gmVsNoviceWins * 10)%)")
        print("  PASS: \(gmVsNoviceWins >= 7 ? "YES" : "NO")")

        print("\n3. Grandmaster vs Grandmaster (3 trials, determinism check)...")
        for i in 0..<3 {
            let r1 = bench.runBotVsBot(
                p1Difficulty: .grandmaster, p1Personality: .balanced,
                p2Difficulty: .grandmaster, p2Personality: .balanced,
                seed: UInt64(i * 5000)
            )
            let r2 = bench.runBotVsBot(
                p1Difficulty: .grandmaster, p1Personality: .balanced,
                p2Difficulty: .grandmaster, p2Personality: .balanced,
                seed: UInt64(i * 5000)
            )
            let deterministic = r1.snapshotHash == r2.snapshotHash
            print("  Trial \(i): P1=\(r1.p1Score) P2=\(r1.p2Score) ticks=\(r1.ticks) deterministic=\(deterministic)")
        }

        print("\n=== Benchmark Complete ===")
    }

    static func runBotVsBot(_ args: [String]) {
        let ticks = intArg(args, "--ticks", default: 200)
        let seed = UInt64(intArg(args, "--seed", default: 12345))
        let diff = difficultyArg(args, default: .grandmaster)
        let pers = personalityArg(args, default: .balanced)
        let debug = args.contains("--debug")

        let board = BoardFactory.triad()
        try? BoardValidator.validate(board)
        var engine = Engine(board: board, matchSeed: seed)
        var bot1 = GrandmasterBot(player: .player1, board: board, seed: seed,
                                  difficulty: diff, personality: pers)
        var bot2 = GrandmasterBot(player: .player2, board: board, seed: seed &+ 1,
                                  difficulty: diff, personality: pers)

        for t in 1...ticks {
            if engine.state.gameStatus != .running { break }
            let cmd1 = bot1.chooseCommand(state: engine.state)
            let cmd2 = bot2.chooseCommand(state: engine.state)
            if debug && t <= 20 {
                print("T\(t): P1=\(cmd1.action) \(cmd1.targetNodeId ?? cmd1.targetEdgeId ?? cmd1.candidateCycleId ?? "-")  P2=\(cmd2.action) \(cmd2.targetNodeId ?? cmd2.targetEdgeId ?? cmd2.candidateCycleId ?? "-")")
            }
            engine.submitTick([cmd1, cmd2])
        }

        let snap = engine.state.snapshot()
        print("Bot vs Bot: P1=\(snap.player1State.score) P2=\(snap.player2State.score) ticks=\(snap.tick) winner=\(snap.winner?.label ?? "draw")")
        print("Moves: P1=\(snap.player1State.moves) P2=\(snap.player2State.moves)")
        if debug {
            var p1n = 0; var p2n = 0; var p1e = 0; var p2e = 0
            for (_, ns) in engine.state.nodes {
                if ns.owner == .player1 { p1n += 1 }
                if ns.owner == .player2 { p2n += 1 }
            }
            for (_, es) in engine.state.edges {
                if es.owner == .player1 { p1e += 1 }
                if es.owner == .player2 { p2e += 1 }
            }
            print("Nodes: P1=\(p1n) P2=\(p2n)  Edges: P1=\(p1e) P2=\(p2e)")
            print("Flux: P1=\(snap.player1State.flux) P2=\(snap.player2State.flux)")
        }
        print("Hash: \(CanonicalEncoding.snapshotHash(snap).prefix(16))")
    }

    static func runBotVsRandom(_ args: [String]) {
        let ticks = intArg(args, "--ticks", default: 200)
        let seed = UInt64(intArg(args, "--seed", default: 12345))
        let diff = difficultyArg(args, default: .grandmaster)
        let pers = personalityArg(args, default: .aggressive)

        let bench = BotBenchmark(maxTicks: ticks)
        let r = bench.runBotVsRandom(
            botDifficulty: diff, botPersonality: pers,
            botPlayer: .player1, seed: seed
        )
        print("Bot vs Random: P1=\(r.p1Score) P2=\(r.p2Score) ticks=\(r.ticks) winner=\(r.winner?.label ?? "draw")")
        print("Moves: P1=\(r.p1Moves) P2=\(r.p2Moves)")
        print("Hash: \(r.snapshotHash.prefix(16))")
    }

    static func validateBoard(_ args: [String]) {
        let boardId = args.count > 2 ? args[2] : "triad"
        let board = resolveBoard(boardId)
        do {
            try BoardValidator.validate(board)
            print("Board '\(boardId)': VALID")
            print("  Nodes: \(board.nodes.count)  Edges: \(board.edges.count)  Faces: \(board.faces.count)")
            print("  Plateaus: \(board.plateaus.count)")
            print("  Anchors: P1=\(board.anchors.player1)  P2=\(board.anchors.player2)")
        } catch {
            print("Board '\(boardId)': INVALID — \(error)")
        }
    }

    static func exportBoard(_ args: [String]) {
        let boardId = args.count > 2 ? args[2] : "triad"
        let board = resolveBoard(boardId)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(board) else {
            print("Failed to encode board")
            return
        }
        // Print to stdout or write to file if --out is specified.
        if let outIdx = args.firstIndex(of: "--out"), outIdx + 1 < args.count {
            let path = args[outIdx + 1]
            try? data.write(to: URL(fileURLWithPath: path))
            print("Exported board '\(boardId)' to \(path) (\(data.count) bytes)")
        } else {
            print(String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func resolveBoard(_ id: String) -> BoardDefinition {
        switch id {
        case "grandmaster": return BoardFactory.grandmaster()
        default: return BoardFactory.triad()
        }
    }

    static func verifyReplay(_ args: [String]) {
        guard args.count > 2 else {
            print("Usage: parallax-tools verify-replay <file>")
            return
        }
        let path = args[2]
        guard let data = FileManager.default.contents(atPath: path) else {
            print("Cannot read file: \(path)")
            return
        }
        do {
            let replay = try Replay.decode(data)
            let board = resolveBoard(replay.boardId)
            let valid = replay.verify(board: board)
            print("Replay: \(valid ? "VALID" : "INVALID")")
            print("  Board: \(replay.boardId)  Ticks: \(replay.durationTicks)")
            print("  Final hash: \(replay.finalSnapshotHash.prefix(16))")
        } catch {
            print("Replay decode error: \(error)")
        }
    }

    // MARK: - Arg parsing

    static func intArg(_ args: [String], _ flag: String, default: Int) -> Int {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count,
              let val = Int(args[idx + 1]) else { return `default` }
        return val
    }

    static func difficultyArg(_ args: [String], default: GrandmasterBot.Difficulty) -> GrandmasterBot.Difficulty {
        guard let idx = args.firstIndex(of: "--difficulty"), idx + 1 < args.count else { return `default` }
        return GrandmasterBot.Difficulty(rawValue: Int(args[idx + 1]) ?? `default`.rawValue) ?? `default`
    }

    static func personalityArg(_ args: [String], default: GrandmasterBot.Personality) -> GrandmasterBot.Personality {
        guard let idx = args.firstIndex(of: "--personality"), idx + 1 < args.count else { return `default` }
        return GrandmasterBot.Personality(rawValue: args[idx + 1]) ?? `default`
    }
}
