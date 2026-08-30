import AppKit
import XCTest
import TacticalCore
@testable import ParallaxApp

final class MatchInputTests: XCTestCase {
    @MainActor
    private func game() -> AppState {
        let app = AppState()
        app.boardId = "triad"
        app.muted = true
        app.audio.muted = true
        app.startHotSeat()
        return app
    }

    @MainActor
    func testCommandShortcutsReachNativeMenus() throws {
        let app = game()
        defer { app.stopMatch() }
        for (key, code) in [("p", UInt16(35)), ("m", UInt16(46)), ("n", UInt16(45))] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command,
                timestamp: 0, windowNumber: 0, context: nil,
                characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: code
            ))
            XCTAssertFalse(app.handleBoardKeyEvent(event, isDown: true), "Command-\(key) must reach its native menu item")
        }
    }

    @MainActor
    func testPointerSelectionDoesNotSpendOrHandOffATurn() {
        let app = game()
        defer { app.stopMatch() }
        let before = app.engine.state.snapshot()
        app.selectBoardNode("p0x1y0")
        XCTAssertEqual(app.selectedNodeId, "p0x1y0")
        XCTAssertEqual(app.hotSeatActivePlayer, .player1)
        XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), CanonicalEncoding.snapshotHash(before))
    }

    @MainActor
    func testInvalidPulseDoesNotHandOffATurn() {
        let app = game()
        defer { app.stopMatch() }
        app.selectedNodeId = "nonexistent-node"
        app.pulseSelectedBoardNode()
        XCTAssertEqual(app.hotSeatActivePlayer, .player1)
        XCTAssertEqual(app.engine.state.tick, 0)
    }

    @MainActor
    func testPausedGameIgnoresActions() {
        let app = game()
        defer { app.stopMatch() }
        app.pauseToggle()
        XCTAssertTrue(app.isPaused)
        app.yieldBoardTurn()
        XCTAssertEqual(app.hotSeatActivePlayer, .player1)
        XCTAssertEqual(app.engine.state.tick, 0)
        app.pauseToggle()
        XCTAssertFalse(app.isPaused)
    }

    @MainActor
    func testMouseSelectionThenSpaceTargetsTheClickedNode() throws {
        let app = game()
        defer { app.stopMatch() }
        app.selectBoardNode("p0x1y0")
        let space = try key(" ", code: 49)
        XCTAssertTrue(app.handleBoardKeyEvent(space, isDown: true))
        XCTAssertEqual(app.hotSeatActivePlayer, .player2)
        app.yieldBoardTurn()
        XCTAssertEqual(app.engine.state.tick, 1)
        XCTAssertEqual(app.engine.state.nodes["p0x1y0"]?.owner, .player1)
    }

    @MainActor
    func testArrowNavigationDoesNotSpendATurn() throws {
        let app = game()
        defer { app.stopMatch() }
        let before = app.engine.state.snapshot()
        XCTAssertTrue(app.handleBoardKeyEvent(try key("\u{F703}", code: 124), isDown: true))
        XCTAssertEqual(app.selectedNodeId, "p0x1y0")
        XCTAssertEqual(app.hotSeatActivePlayer, .player1)
        XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), CanonicalEncoding.snapshotHash(before))
    }

    @MainActor
    func testEscapePausesRatherThanResigns() throws {
        let app = game()
        defer { app.stopMatch() }
        XCTAssertTrue(app.handleBoardKeyEvent(try key("\u{1b}", code: 53), isDown: true))
        XCTAssertTrue(app.isPaused)
        XCTAssertEqual(app.engine.state.gameStatus, .running)
        XCTAssertEqual(app.engine.state.tick, 0)
        XCTAssertEqual(app.hotSeatActivePlayer, .player1)
        XCTAssertTrue(app.handleBoardKeyEvent(try key("\u{1b}", code: 53), isDown: true))
        XCTAssertFalse(app.isPaused)
    }

    @MainActor
    func testUnknownKeyIsNotSwallowed() throws {
        let app = game()
        defer { app.stopMatch() }
        XCTAssertFalse(app.handleBoardKeyEvent(try key("z", code: 6), isDown: true))
    }

    @MainActor
    func testOpeningAcademyStopsCurrentMatch() {
        let app = game()
        defer { app.stopMatch() }
        app.showTraining()
        let before = app.engine.state.snapshot()
        app.advanceTick()
        XCTAssertEqual(app.screen, .training)
        XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), CanonicalEncoding.snapshotHash(before))
    }

    @MainActor
    func testNewMatchClearsTrainingSession() throws {
        let app = game()
        defer { app.stopMatch() }
        let lesson = try XCTUnwrap(TrainingCatalog.lessons.first)
        app.startTrainingLesson(lesson)
        XCTAssertEqual(app.currentLesson?.id, lesson.id)
        app.startHotSeat()
        XCTAssertNil(app.currentLesson)
        XCTAssertFalse(app.trainingComplete)
        XCTAssertEqual(app.screen, .hotseat)
    }

    @MainActor
    func testAllEightLessonsCompleteThroughTheActualActionButtons() {
        let app = game()
        defer { app.stopMatch() }
        for (index, lesson) in TrainingCatalog.lessons.enumerated() {
            app.startTrainingLesson(lesson)
            XCTAssertFalse(app.trainingComplete, lesson.id)
            switch index {
            case 0:
                app.selectBoardNode("p0x1y0")
                app.performBoardAction(.pulse)
            case 1:
                app.selectBoardNode("p0x0y0")
                app.selectedEdgeId = "p0x0y0--p0x1y0"
                app.performBoardAction(.forge)
            case 2:
                app.selectBoardNode("p0x0y0")
                app.selectedEdgeId = "p0x0y0--p0x0y1"
                app.performBoardAction(.forge)
                XCTAssertFalse(app.trainingComplete)
                app.selectedFaceId = "F_p0_x0_y0"
                app.performBoardAction(.seal)
            case 3:
                app.performBoardAction(.reinforce)
            case 4:
                app.selectedEdgeId = "p0x0y0--p1x0y0"
                app.performBoardAction(.traverse)
            case 5:
                app.selectedEdgeId = "p0x3y2--p0x3y3"
                app.performBoardAction(.sever)
            case 6:
                app.selectedEdgeId = "p0x3y2--p0x3y3"
                app.performBoardAction(.counter)
            default:
                app.yieldBoardTurn()
            }
            XCTAssertTrue(app.trainingComplete, "\(lesson.id): \(app.actionFeedback)")
            XCTAssertEqual(app.trainingMoveCount, lesson.parMoves, lesson.id)
            let completed = CanonicalEncoding.snapshotHash(app.engine.state.snapshot())
            app.yieldBoardTurn()
            app.advanceTick()
            XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), completed,
                           "Completed lesson must stay frozen behind its result overlay")
        }
    }

    @MainActor
    func testWindowBridgeDoesNotInterceptMouseHitTesting() {
        let app = game()
        defer { app.stopMatch() }
        let carrier = WindowInputBridge.CarrierView(app: app)
        carrier.frame = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertNil(carrier.hitTest(NSPoint(x: 40, y: 40)))
        carrier.removeMonitor()
        carrier.removeMonitor()
        XCTAssertEqual(carrier.installedMonitorCount, 0)
    }

    @MainActor
    private func key(_ characters: String, code: UInt16) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code
        ))
    }
}
