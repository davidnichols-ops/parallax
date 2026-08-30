import XCTest
@testable import TacticalCore

final class LegalityTests: XCTestCase {

    func testOpeningFluxReserveSupportsExtendedExchange() {
        let state = GameState(board: BoardFactory.triad(), matchSeed: 1)
        XCTAssertEqual(state.playerStates[.player1]?.flux, 15_000)
        XCTAssertEqual(state.playerStates[.player2]?.flux, 15_000)
    }
    var board: BoardDefinition!
    var state: GameState!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
        state = GameState(board: board, matchSeed: 42)
    }

    // MARK: - Select

    func testSelectAnyNodeIsLegal() {
        let cmd = Command.select(.player1, "p0x1y1")
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal)
        XCTAssertEqual(proj.cost, 0)
    }

    func testSelectInvalidNodeRejected() {
        let cmd = Command.select(.player1, "nonexistent")
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .invalidTarget)
    }

    // MARK: - Pulse

    func testPulseAdjacentToAnchorIsLegal() {
        // P1 anchor at (0,0); pulsing (1,0) is adjacent via intra edge.
        let cmd = Command.pulse(.player1, "p0x1y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal, "Pulse adjacent to anchor should be legal")
        XCTAssertEqual(proj.cost, Balance.costPulse)
    }

    func testPulseNonAdjacentRejected() {
        // (2,2) is not adjacent to anchor (0,0) or any owned node.
        let cmd = Command.pulse(.player1, "p0x2y2")
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .notAdjacent)
    }

    func testPulseInsufficientFluxRejected() {
        // Drain P1's flux below cost.
        state.playerStates[.player1]!.flux = 100
        let cmd = Command.pulse(.player1, "p0x1y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .insufficientFlux)
    }

    // MARK: - Forge

    func testForgeBetweenOwnedAndNeutralIsLegal() {
        // P1 owns (0,0); (1,0) is neutral. Edge (0,0)-(1,0) is intra.
        let cmd = Command.forge(.player1, "p0x0y0--p0x1y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal)
    }

    func testForgeConduitRejected() {
        // Conduit edges can't be forged (only traversed).
        // Find a conduit edge.
        let conduit = board.edges.first { $0.kind == .conduit }!
        let cmd = Command.forge(.player1, conduit.id)
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .illegalAction)
    }

    func testForgeEdgeIdOrderInvariant() {
        // "p0x1y0--p0x0y0" should normalize to "p0x0y0--p0x1y0".
        let cmd = Command.forge(.player1, "p0x1y0--p0x0y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal, "Forge should accept either endpoint order")
    }

    // MARK: - Traverse

    func testTraverseConduitFromOwnedEndpointLegal() {
        // P1 owns (0,0) anchor. Find a conduit from plateau 0.
        let conduit = board.edges.first { $0.kind == .conduit && $0.u.hasPrefix("p0") }!
        // Ensure P1 owns one endpoint.
        let endpoint = state.nodes[conduit.u]?.owner == .player1 ? conduit.u : conduit.v
        // If neither endpoint is owned, pulse to capture one first.
        if state.nodes[conduit.u]?.owner != .player1 && state.nodes[conduit.v]?.owner != .player1 {
            // Use the conduit at (0,0) which connects to the anchor.
            let anchorConduit = board.edges.first { $0.kind == .conduit && ($0.u == "p0x0y0" || $0.v == "p0x0y0") }
            XCTAssertNotNil(anchorConduit, "There should be a conduit from P1's anchor")
            let cmd = Command.traverse(.player1, anchorConduit!.id)
            let proj = Legality.project(cmd, state: state)
            XCTAssertTrue(proj.legal, "Traverse from owned anchor conduit should be legal")
        } else {
            _ = endpoint
            let cmd = Command.traverse(.player1, conduit.id)
            let proj = Legality.project(cmd, state: state)
            XCTAssertTrue(proj.legal)
        }
    }

    func testTraverseIntraEdgeRejected() {
        let intra = board.edges.first { $0.kind == .intra }!
        let cmd = Command.traverse(.player1, intra.id)
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .illegalAction)
    }

    // MARK: - Sever

    func testSeverEnemyEdgeLegal() {
        // Set an edge to be owned by P2.
        let edge = board.edges.first { $0.kind == .intra }!
        state.edges[edge.id]!.owner = .player2
        let cmd = Command.sever(.player1, edge.id)
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal)
    }

    func testSeverOwnEdgeRejected() {
        let edge = board.edges.first { $0.kind == .intra }!
        state.edges[edge.id]!.owner = .player1
        let cmd = Command.sever(.player1, edge.id)
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .notEnemyOwned)
    }

    // MARK: - Seal

    func testSealRequiresAllBoundaryEdgesOwned() {
        // F_p0_x0_y0 boundary: top, right, bottom, left.
        // Initially no edges are owned, so seal should fail.
        let cmd = Command.seal(.player1, "F_p0_x0_y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .noCandidateCycle)
    }

    func testSealLegalWhenAllBoundaryEdgesOwned() {
        // Manually set all boundary edges of F_p0_x0_y0 to P1 ownership.
        let face = board.faceMap["F_p0_x0_y0"]!
        for eid in face.boundary {
            state.edges[eid]!.owner = .player1
            state.edges[eid]!.flux = 100
        }
        let cmd = Command.seal(.player1, "F_p0_x0_y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal, "Seal should be legal when all boundary edges are owned")
    }

    // MARK: - Yield

    func testYieldAlwaysLegal() {
        let cmd = Command.yield_(.player1)
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal)
        XCTAssertEqual(proj.cost, 0)
    }

    // MARK: - Resign

    func testResignAlwaysLegal() {
        let cmd = Command.resign(.player1)
        let proj = Legality.project(cmd, state: state)
        XCTAssertTrue(proj.legal)
    }

    // MARK: - Game not running

    func testActionsRejectedWhenGameEnded() {
        state.gameStatus = .ended
        let cmd = Command.pulse(.player1, "p0x1y0")
        let proj = Legality.project(cmd, state: state)
        XCTAssertFalse(proj.legal)
        XCTAssertEqual(proj.reason, .gameNotRunning)
    }
}
