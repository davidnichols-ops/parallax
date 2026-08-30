import XCTest
@testable import TacticalCore

final class DeterminismTests: XCTestCase {
    var board: BoardDefinition!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
    }

    /// The master determinism test: replay the same command stream twice,
    /// assert identical snapshot and event-log hashes.
    func testReplayDeterminism() {
        let commands = makeScript(20)
        let r1 = Engine.replay(board: board, matchSeed: 0xABCD, commands: commands)
        let r2 = Engine.replay(board: board, matchSeed: 0xABCD, commands: commands)
        XCTAssertEqual(
            CanonicalEncoding.snapshotHash(r1.snapshot),
            CanonicalEncoding.snapshotHash(r2.snapshot)
        )
        XCTAssertEqual(r1.logHash, r2.logHash)
    }

    /// Two engines running in lockstep must produce identical per-tick hashes.
    func testLockstepDeterminism() {
        let commands = makeScript(15)
        var eng1 = Engine(board: board, matchSeed: 0x1234)
        var eng2 = Engine(board: board, matchSeed: 0x1234)
        for tickCmds in commands {
            let (s1, _) = eng1.submitTick(tickCmds)
            let (s2, _) = eng2.submitTick(tickCmds)
            let h1 = CanonicalEncoding.snapshotHash(s1)
            let h2 = CanonicalEncoding.snapshotHash(s2)
            XCTAssertEqual(h1, h2, "Lockstep engines diverged at tick \(s1.tick)")
        }
    }

    /// Snapshot hash must be stable (calling it twice on the same snapshot
    /// returns the same value).
    func testSnapshotHashStability() {
        var engine = Engine(board: board, matchSeed: 0x5678)
        engine.submitTick([.select(.player1, "p0x0y0"), .select(.player2, "p0x3y3")])
        let snap = engine.state.snapshot()
        let hashes = (0..<10).map { _ in CanonicalEncoding.snapshotHash(snap) }
        XCTAssertTrue(Set(hashes).count == 1, "Snapshot hash must be deterministic")
    }

    /// Content hash must exclude bookkeeping fields (tick counter, initiative)
    /// so that a no-op tick is correctly detected as "no meaningful change".
    func testContentHashExcludesTickCounter() {
        var engine = Engine(board: board, matchSeed: 0x9ABC)
        // Two ticks with only yields — no meaningful change.
        engine.submitTick([.yield_(.player1), .yield_(.player2)])
        let snap1 = engine.state.snapshot()
        engine.submitTick([.yield_(.player1), .yield_(.player2)])
        let snap2 = engine.state.snapshot()
        // Content hash should be equal (only tick/initiative changed).
        XCTAssertEqual(
            CanonicalEncoding.contentHash(snap1),
            CanonicalEncoding.contentHash(snap2),
            "Content hash should exclude tick counter and initiative flip"
        )
        // But snapshot hash should differ (includes tick).
        XCTAssertNotEqual(
            CanonicalEncoding.snapshotHash(snap1),
            CanonicalEncoding.snapshotHash(snap2),
            "Snapshot hash should differ when tick changes"
        )
    }

    /// The event log hash must be deterministic.
    func testEventLogHashDeterminism() {
        var eng1 = Engine(board: board, matchSeed: 0xDEF0)
        var eng2 = Engine(board: board, matchSeed: 0xDEF0)
        let commands = makeScript(10)
        for tickCmds in commands {
            eng1.submitTick(tickCmds)
            eng2.submitTick(tickCmds)
        }
        XCTAssertEqual(
            CanonicalEncoding.eventLogHash(eng1.log),
            CanonicalEncoding.eventLogHash(eng2.log)
        )
    }

    /// Edge ID normalization: both endpoint orders must produce the same
    /// canonical edge ID.
    func testEdgeIdNormalization() {
        XCTAssertEqual(Legality.canonicalEdgeId("p0x3y3--p0x3y2"), "p0x3y2--p0x3y3")
        XCTAssertEqual(Legality.canonicalEdgeId("p0x0y0--p0x1y0"), "p0x0y0--p0x1y0")
        XCTAssertEqual(Legality.canonicalEdgeId("p0x1y0--p0x0y0"), "p0x0y0--p0x1y0")
    }

    // MARK: - Helpers

    func makeScript(_ ticks: Int) -> [[Command]] {
        var out: [[Command]] = []
        out.append([.select(.player1, "p0x0y0"), .select(.player2, "p0x3y3")])
        let p1Pulses = ["p0x1y0", "p0x2y0", "p0x0y1", "p0x1y1"]
        let p2Pulses = ["p0x2y3", "p0x1y3", "p0x3y2", "p0x2y2"]
        for i in 0..<min(p1Pulses.count, ticks - 1) {
            out.append([.pulse(.player1, p1Pulses[i]), .pulse(.player2, p2Pulses[i])])
        }
        let p1Forges = ["p0x0y0--p0x1y0", "p0x0y0--p0x0y1", "p0x1y0--p0x1y1", "p0x0y1--p0x1y1"]
        let p2Forges = ["p0x2y3--p0x3y3", "p0x3y2--p0x3y3", "p0x2y2--p0x2y3", "p0x2y2--p0x3y2"]
        for i in 0..<min(p1Forges.count, ticks - out.count) {
            out.append([.forge(.player1, p1Forges[i]), .forge(.player2, p2Forges[i])])
        }
        while out.count < ticks {
            out.append([.yield_(.player1), .yield_(.player2)])
        }
        return out
    }
}
