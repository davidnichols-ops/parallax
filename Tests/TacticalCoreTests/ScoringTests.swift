import XCTest
@testable import TacticalCore

final class ScoringTests: XCTestCase {
    var board: BoardDefinition!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
    }

    func testInitialScoreIsZero() {
        let state = GameState(board: board, matchSeed: 1)
        XCTAssertEqual(Scoring.computeScore(.player1, state: state), 0)
        XCTAssertEqual(Scoring.computeScore(.player2, state: state), 0)
    }

    func testInitialParityIsZero() {
        let state = GameState(board: board, matchSeed: 1)
        XCTAssertEqual(Scoring.parity(state: state), 0)
        XCTAssertTrue(Scoring.inParity(state: state))
    }

    func testTerritoryScoreFromControlledFace() {
        var state = GameState(board: board, matchSeed: 1)
        // Give P1 all boundary edges of F_p0_x0_y0.
        let face = board.faceMap["F_p0_x0_y0"]!
        for eid in face.boundary {
            state.edges[eid]!.owner = .player1
            state.edges[eid]!.flux = 100
        }
        Territory.recomputeControl(state: &state)
        let area = Territory.controlledArea(.player1, state: state)
        XCTAssertGreaterThan(area, 0, "P1 should control the face territory")
        let score = Scoring.computeScore(.player1, state: state)
        XCTAssertGreaterThan(score, 0, "P1 should have territory score")
    }

    func testSealedFaceGrantsCycleBonus() {
        var state = GameState(board: board, matchSeed: 1)
        let face = board.faceMap["F_p0_x0_y0"]!
        for eid in face.boundary {
            state.edges[eid]!.owner = .player1
            state.edges[eid]!.flux = 100
        }
        state.faces["F_p0_x0_y0"]!.sealedBy = .player1
        state.faces["F_p0_x0_y0"]!.controller = .player1
        state.playerStates[.player1]!.sealedCycles = 1
        let score = Scoring.computeScore(.player1, state: state)
        // Territory (4*1) + cycle rate (5*1) + cycle bonus (10*1) = 4 + 5 + 10 = 19
        // Plus objective bonus if center face (F_p0_x0_y0 is not center).
        XCTAssertEqual(score, 19, "Sealed face should grant territory + cycle rate + cycle bonus")
    }

    func testPressureCappedAt100() {
        var state = GameState(board: board, matchSeed: 1)
        // Give P1 enough territory to push score over 100.
        // Control many faces with large area.
        for face in board.faces {
            for eid in face.boundary {
                state.edges[eid]!.owner = .player1
                state.edges[eid]!.flux = 100
            }
            state.faces[face.id]!.sealedBy = .player1
            state.faces[face.id]!.controller = .player1
        }
        state.playerStates[.player1]!.sealedCycles = board.faces.count
        let rawScore = Scoring.computeScore(.player1, state: state)
        XCTAssertGreaterThan(rawScore, 100, "Raw score should exceed 100 with full control")
        XCTAssertEqual(Scoring.pressure(.player1, state: state), 100, "Pressure should be capped at 100")
    }

    func testComposureParryOnCounter() {
        var state = GameState(board: board, matchSeed: 1)
        state.playerStates[.player1]!.composure = 50
        let events: [Event] = [
            Event(seq: 0, tick: 1, type: .vectorCountered, player: .player1, payload: [:])
        ]
        let newC = Scoring.applyComposure(.player1, state: state, events: events)
        XCTAssertEqual(newC, 50 + Balance.composureParry + Balance.composureParityHold,
                       "Counter parry + parity hold should increase composure")
    }

    func testComposureMiscommandOnRejection() {
        var state = GameState(board: board, matchSeed: 1)
        state.playerStates[.player1]!.composure = 50
        let events: [Event] = [
            Event(seq: 0, tick: 1, type: .actionRejected, player: .player1, payload: [:])
        ]
        let newC = Scoring.applyComposure(.player1, state: state, events: events)
        XCTAssertEqual(newC, 50 + Balance.composureMiscommand + Balance.composureParityHold)
    }
}

final class TerritoryTests: XCTestCase {
    var board: BoardDefinition!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
    }

    func testNoControlledFacesInitially() {
        let state = GameState(board: board, matchSeed: 1)
        XCTAssertTrue(Territory.controlledFaces(.player1, state: state).isEmpty)
        XCTAssertTrue(Territory.controlledFaces(.player2, state: state).isEmpty)
    }

    func testIsSealableFalseInitially() {
        let state = GameState(board: board, matchSeed: 1)
        XCTAssertFalse(Territory.isSealable("F_p0_x0_y0", by: .player1, state: state))
    }

    func testIsSealableTrueWhenAllBoundaryOwned() {
        var state = GameState(board: board, matchSeed: 1)
        let face = board.faceMap["F_p0_x0_y0"]!
        for eid in face.boundary {
            state.edges[eid]!.owner = .player1
            state.edges[eid]!.flux = 100
        }
        XCTAssertTrue(Territory.isSealable("F_p0_x0_y0", by: .player1, state: state))
    }

    func testBreakCyclesThroughEdge() {
        var state = GameState(board: board, matchSeed: 1)
        let face = board.faceMap["F_p0_x0_y0"]!
        for eid in face.boundary {
            state.edges[eid]!.owner = .player1
            state.edges[eid]!.flux = 100
            state.edges[eid]!.sealed = true
            state.edges[eid]!.sealedCycleIds.append("F_p0_x0_y0")
        }
        state.faces["F_p0_x0_y0"]!.sealedBy = .player1
        state.faces["F_p0_x0_y0"]!.controller = .player1
        // Break through one edge.
        let broken = Territory.breakCyclesThrough(face.boundary[0], state: &state)
        XCTAssertTrue(broken.contains("F_p0_x0_y0"))
        XCTAssertNil(state.faces["F_p0_x0_y0"]?.sealedBy)
    }
}
