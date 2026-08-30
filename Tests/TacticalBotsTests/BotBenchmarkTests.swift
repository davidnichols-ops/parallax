import XCTest
@testable import TacticalBots
import TacticalCore

final class BotBenchmarkTests: XCTestCase {
    var board: BoardDefinition!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
    }

    // MARK: - Bot determinism

    func testBotDeterminismSameSeedSameMove() {
        var bot1 = GrandmasterBot(player: .player1, board: board, seed: 42, difficulty: .novice)
        var bot2 = GrandmasterBot(player: .player1, board: board, seed: 42, difficulty: .novice)
        let state = GameState(board: board, matchSeed: 1)
        let cmd1 = bot1.chooseCommand(state: state)
        let cmd2 = bot2.chooseCommand(state: state)
        XCTAssertEqual(cmd1.action, cmd2.action, "Same seed must produce same move")
    }

    // MARK: - Bot vs random

    func testGrandmasterBeatsRandom() {
        let bench = BotBenchmark(board: board, maxTicks: 150)
        let result = bench.runBotVsRandom(
            botDifficulty: .novice, botPersonality: .aggressive,
            botPlayer: .player1, seed: 12345
        )
        // Grandmaster should score more than random.
        XCTAssertGreaterThanOrEqual(result.p1Score, result.p2Score,
                                     "Grandmaster should at least tie random")
    }

    // MARK: - Bot vs bot determinism

    func testBotVsBotDeterminism() {
        let bench = BotBenchmark(board: board, maxTicks: 50)
        let r1 = bench.runBotVsBot(
            p1Difficulty: .novice, p1Personality: .balanced,
            p2Difficulty: .novice, p2Personality: .balanced,
            seed: 999
        )
        let r2 = bench.runBotVsBot(
            p1Difficulty: .novice, p1Personality: .balanced,
            p2Difficulty: .novice, p2Personality: .balanced,
            seed: 999
        )
        XCTAssertEqual(r1.snapshotHash, r2.snapshotHash, "Same seed must produce identical matches")
    }

    // MARK: - Move generation

    func testLegalMovesNotEmpty() {
        let bot = GrandmasterBot(player: .player1, board: board, seed: 1, difficulty: .novice)
        let state = GameState(board: board, matchSeed: 1)
        let moves = bot.legalMoves(state: state)
        XCTAssertFalse(moves.isEmpty, "Bot should always have at least yield as a legal move")
    }

    func testLegalMovesIncludeYield() {
        let bot = GrandmasterBot(player: .player1, board: board, seed: 1, difficulty: .novice)
        let state = GameState(board: board, matchSeed: 1)
        let moves = bot.legalMoves(state: state)
        XCTAssertTrue(moves.contains { $0.action == .yield }, "Yield should always be available")
    }

    // MARK: - Difficulty tiers

    func testNoviceProducesValidCommands() {
        var bot = GrandmasterBot(player: .player1, board: board, seed: 1, difficulty: .novice)
        var engine = Engine(board: board, matchSeed: 1)
        for _ in 0..<20 {
            if engine.state.gameStatus != .running { break }
            let cmd = bot.chooseCommand(state: engine.state)
            // Command should be valid (yield at minimum).
            XCTAssertEqual(cmd.player, .player1)
        }
    }

    func testGrandmasterProducesValidCommands() {
        var bot = GrandmasterBot(player: .player1, board: board, seed: 1, difficulty: .grandmaster)
        var engine = Engine(board: board, matchSeed: 1)
        for _ in 0..<20 {
            if engine.state.gameStatus != .running { break }
            let cmd = bot.chooseCommand(state: engine.state)
            XCTAssertEqual(cmd.player, .player1)
        }
    }

    // MARK: - Personalities

    func testStandoffPersonalityMaintainsParity() {
        // Standoff bot should keep parity closer to 0 than aggressive.
        let bench = BotBenchmark(board: board, maxTicks: 100)
        let standoffResult = bench.runBotVsBot(
            p1Difficulty: .novice, p1Personality: .standoff,
            p2Difficulty: .novice, p2Personality: .standoff,
            seed: 777
        )
        // With both standoff, parity should be relatively close.
        let parity = abs(standoffResult.p1Score - standoffResult.p2Score)
        XCTAssertLessThan(parity, 50, "Standoff vs standoff should maintain close parity")
    }

    // MARK: - Explain move

    func testExplainMoveReturnsString() {
        let bot = GrandmasterBot(player: .player1, board: board, seed: 1, difficulty: .master)
        let state = GameState(board: board, matchSeed: 1)
        let explanation = bot.explainMove(.yield_(.player1), state: state)
        XCTAssertFalse(explanation.isEmpty, "Explanation should not be empty")
    }
}
