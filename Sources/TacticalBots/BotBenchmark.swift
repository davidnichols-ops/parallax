import Foundation
import TacticalCore

/// Bot benchmark harness. Runs bot vs bot and bot vs random, records results.
public struct BotBenchmark {
    public let board: BoardDefinition
    public let maxTicks: Int

    public init(board: BoardDefinition = BoardFactory.triad(), maxTicks: Int = 200) {
        self.board = board
        self.maxTicks = maxTicks
    }

    public struct Result {
        public let p1Score: Int
        public let p2Score: Int
        public let winner: Player?
        public let ticks: Int
        public let p1Moves: Int
        public let p2Moves: Int
        public let snapshotHash: String
    }

    /// Run a bot vs bot match.
    public func runBotVsBot(p1Difficulty: GrandmasterBot.Difficulty,
                            p1Personality: GrandmasterBot.Personality,
                            p2Difficulty: GrandmasterBot.Difficulty,
                            p2Personality: GrandmasterBot.Personality,
                            seed: UInt64) -> Result {
        var engine = Engine(board: board, matchSeed: seed)
        var bot1 = GrandmasterBot(player: .player1, board: board, seed: seed,
                                  difficulty: p1Difficulty, personality: p1Personality)
        var bot2 = GrandmasterBot(player: .player2, board: board, seed: seed &+ 1,
                                  difficulty: p2Difficulty, personality: p2Personality)

        for _ in 0..<maxTicks {
            if engine.state.gameStatus != .running { break }
            let cmd1 = bot1.chooseCommand(state: engine.state)
            let cmd2 = bot2.chooseCommand(state: engine.state)
            engine.submitTick([cmd1, cmd2])
        }

        let snap = engine.state.snapshot()
        return Result(
            p1Score: snap.player1State.score,
            p2Score: snap.player2State.score,
            winner: snap.winner,
            ticks: snap.tick,
            p1Moves: snap.player1State.moves,
            p2Moves: snap.player2State.moves,
            snapshotHash: CanonicalEncoding.snapshotHash(snap)
        )
    }

    /// Run bot vs random baseline.
    public func runBotVsRandom(botDifficulty: GrandmasterBot.Difficulty,
                                botPersonality: GrandmasterBot.Personality,
                                botPlayer: Player,
                                seed: UInt64) -> Result {
        var engine = Engine(board: board, matchSeed: seed)
        var bot = GrandmasterBot(player: botPlayer, board: board, seed: seed,
                                 difficulty: botDifficulty, personality: botPersonality)
        var rng = SeededRNG(seed: seed &+ 42)

        for _ in 0..<maxTicks {
            if engine.state.gameStatus != .running { break }
            let botCmd = bot.chooseCommand(state: engine.state)
            let oppCmd: Command = botPlayer == .player1
                ? randomCommand(.player2, state: engine.state, board: board, rng: &rng)
                : randomCommand(.player1, state: engine.state, board: board, rng: &rng)
            let cmds = botPlayer == .player1 ? [botCmd, oppCmd] : [oppCmd, botCmd]
            engine.submitTick(cmds)
        }

        let snap = engine.state.snapshot()
        return Result(
            p1Score: snap.player1State.score,
            p2Score: snap.player2State.score,
            winner: snap.winner,
            ticks: snap.tick,
            p1Moves: snap.player1State.moves,
            p2Moves: snap.player2State.moves,
            snapshotHash: CanonicalEncoding.snapshotHash(snap)
        )
    }

    private func randomCommand(_ player: Player, state: GameState, board: BoardDefinition, rng: inout SeededRNG) -> Command {
        let ownedNodes = board.nodes.filter { state.nodes[$0.id]?.owner == player.owner }
        if !ownedNodes.isEmpty, rng.uniform(lessThan: 3) > 0 {
            let src = ownedNodes[rng.uniform(lessThan: ownedNodes.count)]
            let adj = (board.incidence[src.id] ?? []).compactMap { eid -> String? in
                let def = board.edgeMap[eid]!
                if def.kind != .intra { return nil }
                let other = def.u == src.id ? def.v : def.u
                if state.nodes[other]?.owner == .neutral { return other }
                return nil
            }
            if !adj.isEmpty {
                return .pulse(player, adj[rng.uniform(lessThan: adj.count)])
            }
        }
        return .yield_(player)
    }

    /// Verify that grandmaster beats random decisively.
    public func verifyGrandmasterBeatsRandom() -> Bool {
        var wins = 0
        let trials = 10
        for i in 0..<trials {
            let result = runBotVsRandom(
                botDifficulty: .grandmaster, botPersonality: .aggressive,
                botPlayer: .player1, seed: UInt64(i * 1000)
            )
            if result.winner == .player1 || (result.winner == nil && result.p1Score > result.p2Score) {
                wins += 1
            }
        }
        return wins >= trials * 8 / 10  // 80% win rate
    }

    /// Verify that novice is beatable by grandmaster.
    public func verifyNoviceBeatable() -> Bool {
        var gmWins = 0
        let trials = 10
        for i in 0..<trials {
            let result = runBotVsBot(
                p1Difficulty: .grandmaster, p1Personality: .aggressive,
                p2Difficulty: .novice, p2Personality: .balanced,
                seed: UInt64(i * 1000)
            )
            if result.winner == .player1 || (result.winner == nil && result.p1Score > result.p2Score) {
                gmWins += 1
            }
        }
        return gmWins >= trials * 7 / 10  // 70% win rate
    }
}
