import XCTest
@testable import TacticalInput
import TacticalCore

final class InputParserTests: XCTestCase {
    var board: BoardDefinition!
    var parser: InputParser!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
        parser = InputParser(player: .player1, board: board)
    }

    // MARK: - Coordinate keys

    func testRowKeySetsHeldRow() {
        _ = parser.keyDown("q")
        XCTAssertEqual(parser.heldRowValue, 0)  // Q = row 0
    }

    func testColumnKeySetsHeldColumn() {
        _ = parser.keyDown("a")
        XCTAssertEqual(parser.heldColumnValue, 0)  // A = column 0
    }

    func testPlateauKeySetsHeldPlateau() {
        _ = parser.keyDown("j")
        XCTAssertEqual(parser.heldPlateauValue, 0)  // J = plateau 0
    }

    func testFullCoordinateHeld() {
        _ = parser.keyDown("w")  // row 1
        _ = parser.keyDown("s")  // column 1
        _ = parser.keyDown("k")  // plateau 1
        let coord = parser.heldCoordinate
        XCTAssertEqual(coord?.0, 1)
        XCTAssertEqual(coord?.1, 1)
        XCTAssertEqual(coord?.2, 1)
    }

    func testKeyUpClearsHeld() {
        _ = parser.keyDown("q")
        parser.keyUp("q")
        XCTAssertNil(parser.heldCoordinate)
    }

    func testResetClearsAll() {
        _ = parser.keyDown("q")
        _ = parser.keyDown("a")
        _ = parser.keyDown("j")
        parser.reset()
        XCTAssertNil(parser.heldCoordinate)
    }

    // MARK: - Action commands

    func testPulseEmitsCommand() {
        // Hold Q (row 0) + A (column 0) + J (plateau 0) → target p0x0y0
        _ = parser.keyDown("q")
        _ = parser.keyDown("a")
        _ = parser.keyDown("j")
        let cmd = parser.keyDown(" ")  // Space = pulse
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.action, .pulse)
        XCTAssertEqual(cmd?.targetNodeId, "p0x0y0")
        XCTAssertEqual(cmd?.player, .player1)
    }

    func testSelectIsUIOnlyAndDoesNotEmitCommand() {
        _ = parser.keyDown("w")  // row 1
        _ = parser.keyDown("s")  // column 1
        _ = parser.keyDown("j")  // plateau 0
        // Return is UI-only navigation now; it must not emit a game command.
        let cmd = parser.keyDown("\r")
        XCTAssertNil(cmd)
        // But the cursor selection API does move the cursor.
        let target = parser.selectCursor()
        XCTAssertEqual(target, "p0x1y1")
    }

    func testYieldEmitsCommand() {
        let cmd = parser.keyDown("\u{8}")  // Backspace = yield
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.action, .yield)
    }

    func testMacOSDeleteAlsoYields() {
        // 0x7f is the macOS Delete character; it must also yield.
        let cmd = parser.keyDown(Character(UnicodeScalar(0x7f)!))
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.action, .yield)
    }

    func testEscapeDoesNotEmitResignFromParser() {
        // Escape is now pause/resume handled by the app shell, not the parser.
        let cmd = parser.keyDown("\u{1b}")
        XCTAssertNil(cmd)
    }

    func testForgeEmitsCommand() {
        // Set cursor to p0x0y0 first (UI-only select)
        _ = parser.keyDown("q")
        _ = parser.keyDown("a")
        _ = parser.keyDown("j")
        _ = parser.selectCursor()  // select p0x0y0
        // Now hold W+S+J (p0x1y1) and press U (forge)
        _ = parser.keyDown("w")
        _ = parser.keyDown("s")
        _ = parser.keyDown("j")
        let cmd = parser.keyDown("u")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.action, .forge)
        XCTAssertNotNil(cmd?.targetEdgeId)
    }

    // MARK: - Edge ID normalization

    func testForgeProducesCanonicalEdgeId() {
        // Cursor at p0x0y0, target p0x0y1 (W=row1=y1, A=col0=x0)
        _ = parser.keyDown("q")
        _ = parser.keyDown("a")
        _ = parser.keyDown("j")
        _ = parser.selectCursor()  // select p0x0y0
        _ = parser.keyDown("w")   // row 1
        _ = parser.keyDown("a")   // column 0
        _ = parser.keyDown("j")   // plateau 0
        let cmd = parser.keyDown("u")  // forge
        XCTAssertNotNil(cmd)
        // Edge should be canonical: p0x0y0--p0x0y1 (sorted)
        XCTAssertEqual(cmd?.targetEdgeId, "p0x0y0--p0x0y1")
    }

    func testCounterResolverUsesNewestMatchingEnemyAction() {
        let edgeId = "p0x0y0--p0x0y1"
        let intent = Command(player: .player1, action: .counter, targetEdgeId: edgeId)
        let actions = [
            GameState.CounterableAction(seq: 4, player: .player2, action: .forge,
                                        targetEdge: edgeId, targetNode: nil, tick: 8),
            GameState.CounterableAction(seq: 7, player: .player2, action: .sever,
                                        targetEdge: edgeId, targetNode: nil, tick: 8),
            GameState.CounterableAction(seq: 9, player: .player1, action: .forge,
                                        targetEdge: edgeId, targetNode: nil, tick: 8)
        ]

        let resolved = CounterTargetResolver.resolve(intent, counterableActions: actions)
        XCTAssertEqual(resolved.counteredSeq, 7)
    }

    func testCounterResolverLeavesIntentUnresolvedWithoutMatchingEnemyAction() {
        let intent = Command(player: .player1, action: .counter,
                             targetEdgeId: "p0x0y0--p0x0y1")
        let resolved = CounterTargetResolver.resolve(intent, counterableActions: [])
        XCTAssertNil(resolved.counteredSeq)
    }

    // MARK: - No coordinate held

    func testPulseWithoutCoordinateUsesCursor() {
        // No coordinate held — pulse uses cursor (initially anchor p0x0y0)
        let cmd = parser.keyDown(" ")
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.action, .pulse)
    }

    // MARK: - UI-only navigation

    func testNavigateCursorMovesToAdjacentNode() {
        // Cursor starts at p0x0y0; right arrow → p0x1y0.
        let target = parser.navigateCursor(dx: 1, dy: 0)
        XCTAssertEqual(target, "p0x1y0")
        XCTAssertEqual(parser.cursorNodeIdValue, "p0x1y0")
    }

    func testNavigateCursorReturnsNilAtBoardEdge() {
        // Move cursor to a corner and try to go out of bounds.
        _ = parser.navigateCursor(dx: 1, dy: 0)  // p0x1y0
        _ = parser.navigateCursor(dx: 1, dy: 0)  // p0x2y0
        _ = parser.navigateCursor(dx: 1, dy: 0)  // p0x3y0
        let target = parser.navigateCursor(dx: 1, dy: 0)  // out of bounds
        XCTAssertNil(target)
    }

    func testRecognizesReturnsTrueForCoordinateKeys() {
        XCTAssertTrue(parser.recognizes("q"))
        XCTAssertTrue(parser.recognizes("a"))
        XCTAssertTrue(parser.recognizes("j"))
    }

    func testRecognizesReturnsFalseForUnknownKeys() {
        XCTAssertFalse(parser.recognizes("z"))
        XCTAssertFalse(parser.recognizes("9"))
    }

    // MARK: - Custom mapping

    func testCustomMapping() {
        let custom = InputMapping(
            rowKeys: ["1", "2", "3", "4"],
            columnKeys: ["z", "x", "c", "v"],
            plateauKeys: ["n", "m", ","]
        )
        let p = InputParser(mapping: custom, player: .player1, board: board)
        _ = p.keyDown("2")  // row 1
        _ = p.keyDown("x")  // column 1
        _ = p.keyDown("m")  // plateau 1
        XCTAssertEqual(p.heldCoordinate?.0, 1)
        XCTAssertEqual(p.heldCoordinate?.1, 1)
        XCTAssertEqual(p.heldCoordinate?.2, 1)
    }
}
