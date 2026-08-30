import XCTest
@testable import TacticalCore

/// Verified reference solutions and structural guarantees for the Academy
/// training lessons. Each solution drives both players' commands deterministically
/// (the trainee is Player 1; Player 2 yields unless a lesson needs an opponent
/// tempo). Goal predicates are outcome-based, so the "rejected never completes"
/// and "distinct failure" tests confirm that `actionRejected` events alone can
/// never satisfy a lesson.
final class TrainingTests: XCTestCase {

    // MARK: - Catalog shape

    func testCatalogHasEightLessonsWithDistinctIds() {
        let lessons = TrainingCatalog.lessons
        XCTAssertEqual(lessons.count, 8, "Catalog must contain exactly 8 lessons")
        let ids = lessons.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "Lesson ids must be distinct")
        for l in lessons {
            XCTAssertFalse(l.title.isEmpty, "\(l.id): title empty")
            XCTAssertFalse(l.briefing.isEmpty, "\(l.id): briefing empty")
            XCTAssertFalse(l.objective.isEmpty, "\(l.id): objective empty")
            XCTAssertFalse(l.hint.isEmpty, "\(l.id): hint empty")
            XCTAssertFalse(l.initialSelection.isEmpty, "\(l.id): initialSelection empty")
            XCTAssertGreaterThan(l.parMoves, 0, "\(l.id): parMoves must be positive")
        }
    }

    func testAllLessonBoardsValidate() throws {
        for l in TrainingCatalog.lessons {
            XCTAssertNoThrow(try BoardValidator.validate(l.board),
                             "\(l.id): board must validate")
            XCTAssertTrue(l.board.id == "triad" || l.board.id == "grandmaster",
                          "\(l.id): board id must be triad or grandmaster for replay lookup")
        }
    }

    // MARK: - Initially incomplete + rejected never completes

    func testAllLessonsInitiallyIncomplete() {
        for l in TrainingCatalog.lessons {
            let engine = l.makeEngine()
            let complete = l.isComplete(state: engine.state, events: [])
            XCTAssertFalse(complete, "\(l.id): must start incomplete")
        }
    }

    /// A rejected action alone must never complete any lesson. Every predicate
    /// inspects real state, not event types, so an `actionRejected` event cannot
    /// satisfy completion.
    func testRejectedActionsNeverComplete() {
        for l in TrainingCatalog.lessons {
            var engine = l.makeEngine()
            // P1 attempts to sever a neutral/own edge (always rejected with
            // notEnemyOwned for these starting positions); P2 yields to advance.
            let (_, events) = engine.submitTick([
                .sever(.player1, "p0x0y0--p0x1y0"),
                .yield_(.player2)
            ])
            XCTAssertTrue(events.contains { $0.type == .actionRejected },
                          "\(l.id): setup should produce a rejection")
            XCTAssertFalse(l.isComplete(state: engine.state, events: events),
                           "\(l.id): rejected action must not complete the lesson")
        }
    }

    // MARK: - Reference solutions

    func testLesson1PulseFirstCapture() {
        let l = TrainingCatalog.lessons[0]
        XCTAssertEqual(l.id, "pulse-first-capture")
        var engine = l.makeEngine()
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.pulse(.player1, "p0x1y0"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Pulse p0x1y0 should complete lesson 1")
        XCTAssertEqual(engine.state.nodes["p0x1y0"]?.owner, .player1)
        XCTAssertEqual(engine.state.nodes["p0x1y0"]?.influence, 100)
    }

    func testLesson2ForgeClaimLink() {
        let l = TrainingCatalog.lessons[1]
        XCTAssertEqual(l.id, "forge-claim-link")
        var engine = l.makeEngine()
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Forge p0x0y0--p0x1y0 should complete lesson 2")
        XCTAssertEqual(engine.state.edges["p0x0y0--p0x1y0"]?.owner, .player1)
    }

    func testLesson3SealCloseCycle() {
        let l = TrainingCatalog.lessons[2]
        XCTAssertEqual(l.id, "seal-close-cycle")
        var engine = l.makeEngine()
        var all: [Event] = []
        // Forge the missing left edge.
        let (_, e1) = engine.submitTick([.forge(.player1, "p0x0y0--p0x0y1"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertFalse(l.isComplete(state: engine.state, events: all),
                       "Forging alone should not complete the seal lesson")
        // Seal the face.
        let (_, e2) = engine.submitTick([.seal(.player1, "F_p0_x0_y0"), .yield_(.player2)])
        all.append(contentsOf: e2)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Forge + seal should complete lesson 3")
        XCTAssertEqual(engine.state.faces["F_p0_x0_y0"]?.sealedBy, .player1)
    }

    func testLesson4ReinforceAnchorShield() {
        let l = TrainingCatalog.lessons[3]
        XCTAssertEqual(l.id, "reinforce-anchor-shield")
        var engine = l.makeEngine()
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.reinforce(.player1, "p0x0y0"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Reinforce should open a shield window on p0x0y0")
        XCTAssertGreaterThan(engine.state.nodes["p0x0y0"]?.shieldTicks ?? 0, 0)
    }

    func testLesson5TraverseCrossConduit() {
        let l = TrainingCatalog.lessons[4]
        XCTAssertEqual(l.id, "traverse-cross-conduit")
        var engine = l.makeEngine()
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.traverse(.player1, "p0x0y0--p1x0y0"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Traverse should claim p1x0y0 for P1")
        XCTAssertEqual(engine.state.nodes["p1x0y0"]?.owner, .player1)
        XCTAssertEqual(engine.state.edges["p0x0y0--p1x0y0"]?.owner, .player1)
    }

    func testLesson6SeverCutEnemyLine() {
        let l = TrainingCatalog.lessons[5]
        XCTAssertEqual(l.id, "sever-cut-enemy-line")
        var engine = l.makeEngine()
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.sever(.player1, "p0x3y2--p0x3y3"), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Sever should cut the enemy edge")
        XCTAssertTrue(engine.state.edges["p0x3y2--p0x3y3"]?.severed ?? false)
    }

    func testLesson7CounterParryVector() {
        let l = TrainingCatalog.lessons[6]
        XCTAssertEqual(l.id, "counter-parry-vector")
        var engine = l.makeEngine()
        // makeEngine() pre-ran tick 1: P2 forged p0x3y2--p0x3y3 (counterable).
        XCTAssertEqual(engine.state.tick, 1, "Counter lesson engine starts after tick 1")
        let counterable = engine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }
        XCTAssertNotNil(counterable, "A counterable forge must be on record")
        let seq = counterable!.seq
        var all: [Event] = []
        let (_, e2) = engine.submitTick([
            .counter(.player1, "p0x3y2--p0x3y3", counteredSeq: seq),
            .yield_(.player2)
        ])
        all.append(contentsOf: e2)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Counter should complete lesson 7")
        XCTAssertGreaterThanOrEqual(
            engine.state.playerStates[.player1]?.successfulCounters ?? 0, 1)
        XCTAssertTrue(all.contains { $0.type == .vectorCountered })
    }

    func testLesson8YieldHoldParity() {
        let l = TrainingCatalog.lessons[7]
        XCTAssertEqual(l.id, "yield-hold-parity")
        var engine = l.makeEngine()
        // The starting position is balanced (in parity) but no yield yet.
        XCTAssertFalse(l.isComplete(state: engine.state, events: []),
                       "Yield lesson needs an actual yield event to complete")
        var all: [Event] = []
        let (_, e1) = engine.submitTick([.yield_(.player1), .yield_(.player2)])
        all.append(contentsOf: e1)
        XCTAssertTrue(l.isComplete(state: engine.state, events: all),
                      "Yield while in parity should complete lesson 8")
        XCTAssertTrue(all.contains { $0.type == .yieldIssued && $0.player == .player1 })
        XCTAssertTrue(Scoring.inParity(state: engine.state))
    }

    // MARK: - Distinct failure cases (not config repetition)

    /// Each lesson has a distinct wrong action that must NOT complete it. This
    /// guards against predicates that are satisfied by the starting position or
    /// by incidental state changes from an unrelated action.
    func testDistinctFailureCases() {
        let lessons = TrainingCatalog.lessons

        // Lesson 1 (pulse): forging instead of pulsing leaves p0x1y0 neutral.
        runFailure(lessons[0], ticks: [[.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)]])

        // Lesson 2 (forge): pulsing the node instead of forging the edge.
        runFailure(lessons[1], ticks: [[.pulse(.player1, "p0x1y0"), .yield_(.player2)]])

        // Lesson 3 (seal): forging only the left edge but not sealing.
        runFailure(lessons[2], ticks: [[.forge(.player1, "p0x0y0--p0x0y1"), .yield_(.player2)]])

        // Lesson 4 (reinforce): selecting instead of reinforcing.
        runFailure(lessons[3], ticks: [[.select(.player1, "p0x0y0"), .yield_(.player2)]])

        // Lesson 5 (traverse): pulsing instead of traversing the conduit.
        runFailure(lessons[4], ticks: [[.pulse(.player1, "p0x1y0"), .yield_(.player2)]])

        // Lesson 6 (sever): forging own edge instead of severing enemy edge.
        runFailure(lessons[5], ticks: [[.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)]])

        // Lesson 7 (counter): yielding instead of countering (window then closes).
        runFailure(lessons[6], ticks: [[.yield_(.player1), .yield_(.player2)]])

        // Lesson 8 (yield/parity): pulsing instead of yielding (no yield event).
        runFailure(lessons[7], ticks: [[.pulse(.player1, "p0x1y0"), .yield_(.player2)]])
    }

    // MARK: - Helpers

    /// Drive `lesson` with the given per-tick command lists and assert the
    /// lesson is NOT complete afterwards.
    private func runFailure(_ lesson: TrainingLesson, ticks: [[Command]]) {
        var engine = lesson.makeEngine()
        var all: [Event] = []
        for cmds in ticks {
            let (_, ev) = engine.submitTick(cmds)
            all.append(contentsOf: ev)
        }
        XCTAssertFalse(lesson.isComplete(state: engine.state, events: all),
                       "\(lesson.id): wrong action sequence must not complete the lesson")
    }
}
