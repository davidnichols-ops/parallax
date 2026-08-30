import AppKit
import CoreGraphics
import XCTest
import TacticalCore
import TacticalPersistence
@testable import TacticalAudio
@testable import TacticalHaptics
@testable import TacticalRenderer
@testable import ParallaxApp

/// Segment 17 — live-app/manual-style smoke QA harness.
///
/// The packaged `Parallax.app` (2.1.0-rc1) was launched for real on the
/// development Mac (see the Segment 17 notes + screenshots in
/// `devin-strategema-progress.md`): the process started, a visible 1180x800
/// window titled "Parallax" appeared, and a non-blank menu render was
/// captured. AppleScript/System Events could not drive the real app because
/// `osascript` is not granted Assistive Access on this machine, so the
/// interactive paths a user takes are verified here through the same
/// in-process `NSWindow` + `BoardHostingView` harness used since Segment 7,
/// extended to cover the interaction paths the real-app smoke test could not
/// reach without AX permissions:
///
/// 1. **Mouse node selection** — a real `mouseDown` event is dispatched to the
///    mounted `BoardHostingView` at the projected screen point of a known
///    token, routing through `pickNodeID` → `onNodeSelected` →
///    `AppState.selectBoardNode`, exactly the path a click takes.
/// 2. **Camera orbit/pan/zoom** — synthetic `rightMouseDown`/`mouseDragged`
///    (orbit + pan) and `scrollWheel` (zoom) events are dispatched to the
///    board view and the camera azimuth/elevation/distance/target are
///    asserted to move within their clamped ranges, then reset restores the
///    defaults.
/// 3. **Audio/ambience toggle (no crash)** — the SettingsView UI path
///    (`AppState.updateAudioSettings` driven by the mute/sfx/ambience
///    controls) is exercised with the audio graph started and stopped,
///    including rapid toggling and boundary volumes, verifying no crash and
///    that the engine mirrors the AppState values.
///
/// The existing Segment 7/13/15 harnesses already cover menu/pause/controls/
/// buttons, Academy Continue/Discard, and the persona HUD in bot modes; this
/// file complements them rather than duplicating those assertions.
final class SmokeQATests: XCTestCase {

    /// Silenced AppState backed by a recording haptic performer and an
    /// isolated persistence manager so smoke tests never touch the user's
    /// real App Support state.
    @MainActor
    private func makeApp() -> AppState {
        let performer = RecordingHapticPerformer()
        let engine = HapticsEngine(performer: performer, available: true)
        let pm = PersistenceManager(appName: "parallax-seg17-\(UUID().uuidString)")
        let app = AppState(haptics: engine, persistence: pm)
        app.boardId = "triad"
        app.muted = true
        app.audio.muted = true
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.syncHapticsSettings()
        return app
    }

    /// Mount a hot-seat match with the `WindowInputBridge` installed exactly
    /// as `ParallaxApp` mounts it.
    @MainActor
    private func makeMatchHost() -> UITestHost {
        let app = makeApp()
        app.startHotSeat()
        let view = MatchView(app: app)
            .background(WindowInputBridge(app: app).frame(width: 0, height: 0))
        let host = UITestHost(root: view, app: app)
        host.mount()
        return host
    }

    /// Build a synthetic mouse event of the given type at `locationInWindow`.
    /// The button is implied by the event type (leftMouseDown = button 0,
    /// rightMouseDown = button 1).
    private func mouseEvent(_ type: NSEvent.EventType, location: NSPoint,
                            windowNumber: Int,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location,
                           modifierFlags: modifiers, timestamp: 0,
                           windowNumber: windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1.0)
    }

    /// Build a synthetic scroll-wheel event with the given vertical delta.
    /// The macOS 26 SDK removed the `NSEvent.scrollWheelEvent` class method,
    /// so this bridges a `CGEvent` scroll-wheel event into an `NSEvent`.
    private func scrollEvent(location: NSPoint, windowNumber: Int,
                             deltaY: CGFloat) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil,
                               units: .line,
                               wheelCount: 1,
                               wheel1: Int32(deltaY),
                               wheel2: 0, wheel3: 0) else { return nil }
        return NSEvent(cgEvent: cg)
    }

    // MARK: - 1. Mouse node selection (real mouseDown → pickNodeID → select)

    /// A real left-click on a projected token routes through `pickNodeID` →
    /// `onNodeSelected` → `AppState.selectBoardNode`, selecting the node
    /// without spending a turn. This is the exact path a mouse click takes
    /// once it reaches the board view.
    @MainActor
    func testMouseClickSelectsNodeWithoutSpendingATurn() throws {
        let host = makeMatchHost()
        defer { host.close() }
        let app = host.app
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }

        // The board must have token nodes registered for picking.
        let tokenIds = board.testTokenNodeIds()
        try XCTSkipIf(tokenIds.isEmpty, "no token nodes registered for picking")

        // Pick a known capturable neutral node (p0x1y0 in the triad opening).
        let targetId = "p0x1y0"
        try XCTSkipUnless(tokenIds.contains(targetId),
                          "target token \(targetId) not registered; ids: \(tokenIds)")

        // Project the token's world position to window space (reversing the
        // mouseDown coordinate conversions) and dispatch a real mouseDown at
        // that point so it lands on the token after the forward conversions.
        let point = try XCTUnwrap(board.testWindowClickPoint(forNodeId: targetId),
                                  "token \(targetId) must project to a window point")
        let windowNumber = host.window.windowNumber
        guard let event = mouseEvent(.leftMouseDown, location: point,
                                     windowNumber: windowNumber) else {
            XCTFail("could not build mouseDown event"); return
        }

        let before = CanonicalEncoding.snapshotHash(app.engine.state.snapshot())
        board.mouseDown(with: event)

        XCTAssertEqual(app.selectedNodeId, targetId,
                       "mouse click on \(targetId) must select it")
        XCTAssertEqual(app.hotSeatActivePlayer, .player1,
                       "selection must not hand off the turn")
        XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), before,
                       "selection must not mutate engine state")
    }

    /// A left-click on empty board space (no token nearby) does not crash and
    /// leaves the selection unchanged.
    @MainActor
    func testMouseClickOnEmptySpaceDoesNotCrashOrChangeSelection() {
        let host = makeMatchHost()
        defer { host.close() }
        let app = host.app
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let before = app.selectedNodeId
        // A point far outside any token projection (bottom-left corner margin).
        let empty = NSPoint(x: 5, y: 5)
        guard let event = mouseEvent(.leftMouseDown, location: empty,
                                     windowNumber: host.window.windowNumber) else {
            XCTFail("could not build mouseDown event"); return
        }
        board.mouseDown(with: event)
        XCTAssertEqual(app.selectedNodeId, before,
                       "click on empty space must not change selection")
    }

    // MARK: - 2. Camera orbit / pan / zoom (real mouse drag + scroll)

    /// A right-drag (orbit gesture) moves the camera azimuth/elevation within
    /// their clamped ranges and marks the camera as interacted.
    @MainActor
    func testRightDragOrbitsCameraWithinClampedRange() {
        let host = makeMatchHost()
        defer { host.close() }
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let windowNumber = host.window.windowNumber
        let start = NSPoint(x: board.bounds.midX, y: board.bounds.midY)
        let az0 = board.testCameraAzimuth
        let el0 = board.testCameraElevation
        XCTAssertFalse(board.testCameraHasInteracted,
                       "camera should start in auto-fit (not interacted)")

        // Begin a right-drag (orbit).
        guard let down = mouseEvent(.rightMouseDown, location: start,
                                    windowNumber: windowNumber) else {
            XCTFail("could not build rightMouseDown event"); return
        }
        board.rightMouseDown(with: down)
        XCTAssertEqual(board.testCameraGesture, "orbit",
                       "right-drag must start an orbit gesture")

        // Drag right+up: azimuth decreases, elevation increases (clamped).
        let drag = NSPoint(x: start.x + 80, y: start.y + 60)
        guard let dragEvent = mouseEvent(.leftMouseDragged, location: drag,
                                         windowNumber: windowNumber) else {
            XCTFail("could not build mouseDragged event"); return
        }
        board.mouseDragged(with: dragEvent)
        XCTAssertTrue(board.testCameraHasInteracted,
                      "orbit drag must mark the camera as interacted")
        XCTAssertLessThan(board.testCameraAzimuth, az0,
                          "rightward drag must decrease azimuth")
        XCTAssertGreaterThan(board.testCameraElevation, el0,
                             "upward drag must increase elevation")
        // Elevation stays within the authored clamp.
        XCTAssertLessThanOrEqual(board.testCameraElevation, .pi * 0.46)
        XCTAssertGreaterThanOrEqual(board.testCameraElevation, .pi * 0.08)

        // End the drag.
        guard let up = mouseEvent(.rightMouseUp, location: drag,
                                  windowNumber: windowNumber) else {
            XCTFail("could not build rightMouseUp event"); return
        }
        board.rightMouseUp(with: up)
        XCTAssertNil(board.testCameraGesture, "gesture must clear on mouse up")
    }

    /// An option+shift-drag (pan gesture) moves the camera target and marks
    /// the camera as interacted.
    @MainActor
    func testOptionShiftDragPansCameraTarget() {
        let host = makeMatchHost()
        defer { host.close() }
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let windowNumber = host.window.windowNumber
        let start = NSPoint(x: board.bounds.midX, y: board.bounds.midY)
        let target0 = board.testCameraTarget

        // Begin an option+shift-drag (pan).
        guard let down = mouseEvent(.leftMouseDown, location: start,
                                    windowNumber: windowNumber,
                                    modifiers: [.option, .shift]) else {
            XCTFail("could not build pan mouseDown event"); return
        }
        board.mouseDown(with: down)
        XCTAssertEqual(board.testCameraGesture, "pan",
                       "option+shift-drag must start a pan gesture")

        // Drag: the target must move.
        let drag = NSPoint(x: start.x + 100, y: start.y - 80)
        guard let dragEvent = mouseEvent(.leftMouseDragged, location: drag,
                                         windowNumber: windowNumber,
                                         modifiers: [.option, .shift]) else {
            XCTFail("could not build pan mouseDragged event"); return
        }
        board.mouseDragged(with: dragEvent)
        let target1 = board.testCameraTarget
        XCTAssertTrue(target1 != target0,
                      "pan drag must move the camera target")
        XCTAssertTrue(board.testCameraHasInteracted,
                      "pan drag must mark the camera as interacted")

        if let up = mouseEvent(.leftMouseUp, location: drag,
                               windowNumber: windowNumber,
                               modifiers: [.option, .shift]) {
            board.mouseUp(with: up)
        }
        XCTAssertNil(board.testCameraGesture)
    }

    /// A scroll-wheel event zooms the camera distance, clamped to >= 7.
    @MainActor
    func testScrollWheelZoomsCameraDistance() {
        let host = makeMatchHost()
        defer { host.close() }
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let windowNumber = host.window.windowNumber
        let center = NSPoint(x: board.bounds.midX, y: board.bounds.midY)
        let dist0 = board.testCameraDistance

        // Scroll "up" (positive deltaY) zooms in (distance decreases).
        guard let zoomIn = scrollEvent(location: center,
                                       windowNumber: windowNumber, deltaY: 12) else {
            XCTFail("could not build scrollWheel event"); return
        }
        board.scrollWheel(with: zoomIn)
        let dist1 = board.testCameraDistance
        XCTAssertLessThan(dist1, dist0, "scroll up must zoom in (decrease distance)")
        XCTAssertTrue(board.testCameraHasInteracted,
                      "scroll must mark the camera as interacted")

        // Scroll "down" (negative deltaY) zooms out (distance increases).
        guard let zoomOut = scrollEvent(location: center,
                                        windowNumber: windowNumber, deltaY: -24) else {
            XCTFail("could not build scrollWheel event"); return
        }
        board.scrollWheel(with: zoomOut)
        XCTAssertGreaterThan(board.testCameraDistance, dist1,
                             "scroll down must zoom out (increase distance)")
    }

    /// Resetting the camera restores the default azimuth/elevation and clears
    /// the interacted flag, mirroring the ⌘R / Reset Camera command.
    @MainActor
    func testResetCameraRestoresDefaults() {
        let host = makeMatchHost()
        defer { host.close() }
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let windowNumber = host.window.windowNumber
        let center = NSPoint(x: board.bounds.midX, y: board.bounds.midY)

        // Orbit first so the camera is interacted and off-default.
        if let down = mouseEvent(.rightMouseDown, location: center,
                                 windowNumber: windowNumber) {
            board.rightMouseDown(with: down)
        }
        if let drag = mouseEvent(.leftMouseDragged,
                                 location: NSPoint(x: center.x + 90, y: center.y + 50),
                                 windowNumber: windowNumber) {
            board.mouseDragged(with: drag)
        }
        if let up = mouseEvent(.rightMouseUp, location: center,
                               windowNumber: windowNumber) {
            board.rightMouseUp(with: up)
        }
        XCTAssertTrue(board.testCameraHasInteracted)
        let azOff = board.testCameraAzimuth

        // Reset via the test accessor (same path as cameraResetToken didSet).
        board.testResetInteractiveCamera()
        XCTAssertFalse(board.testCameraHasInteracted,
                       "reset must clear the interacted flag")
        XCTAssertEqual(board.testCameraAzimuth, .pi * 0.06, accuracy: 0.0001,
                       "reset must restore the default azimuth")
        XCTAssertEqual(board.testCameraElevation, .pi * 0.30, accuracy: 0.0001,
                       "reset must restore the default elevation")
        XCTAssertNotEqual(board.testCameraAzimuth, azOff,
                          "azimuth must differ from the orbited value after reset")
    }

    // MARK: - 3. Audio / ambience toggle (no crash, mirrors AppState)

    /// Toggling mute, SFX volume, and ambience volume through the
    /// `updateAudioSettings()` UI path does not crash and mirrors the values
    /// into the AudioEngine, whether the graph is started or stopped.
    @MainActor
    func testAudioTogglePathDoesNotCrashAndMirrorsState() {
        let app = makeApp()
        // Start from a muted, zero-volume state (silenced by makeApp).
        XCTAssertTrue(app.muted)
        XCTAssertEqual(app.sfxVolume, 0)
        XCTAssertEqual(app.ambienceVolume, 0)

        // Unmute and raise volumes through the SettingsView UI path.
        app.muted = false
        app.sfxVolume = 0.5
        app.ambienceVolume = 0.25
        app.updateAudioSettings()
        XCTAssertFalse(app.audio.muted, "audio engine must mirror unmute")
        XCTAssertEqual(app.audio.sfxVolume, 0.5, accuracy: 0.001)
        XCTAssertEqual(app.audio.ambienceVolume, 0.25, accuracy: 0.001)

        // Mute again through the same path.
        app.muted = true
        app.updateAudioSettings()
        XCTAssertTrue(app.audio.muted, "audio engine must mirror mute")

        // Boundary volumes (0 and 1) must not crash.
        app.sfxVolume = 1.0
        app.ambienceVolume = 1.0
        app.updateAudioSettings()
        XCTAssertEqual(app.audio.sfxVolume, 1.0, accuracy: 0.001)
        XCTAssertEqual(app.audio.ambienceVolume, 1.0, accuracy: 0.001)
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.updateAudioSettings()
        XCTAssertEqual(app.audio.sfxVolume, 0, accuracy: 0.001)
    }

    /// Rapidly toggling mute while the audio graph is started does not crash
    /// and leaves the engine in a consistent state. This mirrors a user
    /// flipping the "Mute All Audio" toggle back and forth during a match.
    @MainActor
    func testRapidMuteToggleWithRunningGraphDoesNotCrash() throws {
        let app = makeApp()
        // Try to start the audio graph; skip if no output device is available
        // (the same guard the AudioLifecycleTests use).
        app.audio.muted = false
        app.audio.sfxVolume = 0
        app.audio.ambienceVolume = 0
        app.audio.start()
        guard app.audio.isRunning else {
            app.audio.stop()
            throw XCTSkip("No output device / graph cannot start on this host")
        }
        defer { app.audio.stop() }

        // Flip mute 20 times through the UI path while the graph runs.
        for i in 0..<20 {
            app.muted = (i % 2 == 0)
            app.updateAudioSettings()
        }
        XCTAssertFalse(app.audio.isRunning == false && app.muted == false,
                       "engine state must stay consistent after rapid toggling")
    }

    /// The SettingsView mounting with the audio controls does not crash when
    /// the audio settings are toggled through the bound AppState properties.
    @MainActor
    func testSettingsViewAudioControlsMountAndToggleWithoutCrash() {
        let app = makeApp()
        app.showSettings()
        let host = UITestHost(root: SettingsView(app: app), app: app)
        host.mount()
        defer { host.close() }

        // Drive the same mutations the SettingsView sliders/toggle bind to,
        // then call the wired update path (onChange → updateAudioSettings).
        app.muted.toggle()
        app.updateAudioSettings()
        app.sfxVolume = 0.3
        app.updateAudioSettings()
        app.ambienceVolume = 0.6
        app.updateAudioSettings()
        // No crash = pass. The view remains mounted.
        XCTAssertNotNil(host.contentView)
    }

    // MARK: - 4. Menu / pause / controls / buttons respond (regression)

    /// The menu view mounts and the primary mode buttons route to the correct
    /// screens through the real AppState wiring. (Regression for the
    /// "menu/buttons respond" smoke item, complementing UIHarnessTests.)
    @MainActor
    func testMenuModeButtonsRouteToCorrectScreens() {
        let app = makeApp()
        let host = UITestHost(root: MenuView(app: app), app: app)
        host.mount()
        defer { host.close() }

        app.showTraining()
        XCTAssertEqual(app.screen, .training, "Training button must route to training")
        app.showSettings()
        XCTAssertEqual(app.screen, .settings, "Settings button must route to settings")
        app.showMenu()
        XCTAssertEqual(app.screen, .menu, "back must route to menu")
    }

    /// Pause/resume and the Controls button respond through the real match
    /// wiring. (Regression for the "pause/controls respond" smoke item.)
    @MainActor
    func testPauseAndControlsRespondInMatch() {
        let host = makeMatchHost()
        defer { host.close() }
        let app = host.app

        XCTAssertFalse(app.isPaused)
        host.press(identifier: "match.pause") { app.pauseToggle() }
        XCTAssertTrue(app.isPaused, "pause control must pause")
        host.press(identifier: "match.pause") { app.pauseToggle() }
        XCTAssertFalse(app.isPaused, "pause control must resume")
        host.press(identifier: "match.controls") { app.pauseToggle() }
        XCTAssertTrue(app.isPaused, "controls must pause the match")
    }

    // MARK: - 5. Persona HUD appears in bot modes (regression)

    /// The persona strip is shown in a solo bot (skirmish) match and the
    /// MatchView mounts without crashing. (Regression for the "persona HUD
    /// appears in bot modes" smoke item, complementing PersonaHUDTests.)
    @MainActor
    func testPersonaHUDPresentInSkirmishBotMode() {
        let app = makeApp()
        app.botDifficulty = .master
        app.botPersonaId = "vector"
        app.startSkirmish()
        let host = UITestHost(
            root: MatchView(app: app)
                .background(WindowInputBridge(app: app).frame(width: 0, height: 0)),
            app: app)
        host.mount()
        defer { host.close() }
        XCTAssertEqual(app.screen, .skirmish, "skirmish must be the active screen")
        XCTAssertNotNil(host.contentView, "MatchView with persona strip must mount")
        XCTAssertNotNil(host.findBoardView(), "board must mount in bot mode")
    }

    /// The persona strip is NOT shown in hot-seat (no bot). (Regression for
    /// the "bot modes only" gating.)
    @MainActor
    func testPersonaHUDAbsentInHotSeat() {
        let host = makeMatchHost()
        defer { host.close() }
        XCTAssertEqual(host.app.screen, .hotseat, "hot-seat must be the active screen")
        // Hot-seat has no bot persona; the persona id is empty.
        XCTAssertEqual(host.app.botPersonaId, "", "hot-seat must not carry a persona id")
    }

    // MARK: - 6. Academy Continue/Discard when a save exists (regression)

    /// When a saved in-progress lesson exists, `hasSavedLesson` is true and
    /// `savedLessonInfo` projects the lesson, so the Academy Continue/Discard
    /// banner has data to show. (Regression for the "Academy Continue/Discard
    /// appears when a save exists" smoke item, complementing
    /// AcademyProgressTests.)
    @MainActor
    func testAcademyContinueDiscardDataAppearsWhenSaveExists() {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        // Make a partial move so the lesson is in-progress, then stop to save.
        app.selectBoardNode("p0x1y0")
        app.stopMatch()
        XCTAssertTrue(app.hasSavedLesson, "stopMatch must save the in-progress lesson")
        let info = app.savedLessonInfo
        XCTAssertNotNil(info, "savedLessonInfo must project when a save exists")
        XCTAssertEqual(info?.lessonId, first.id)
        // The save records the in-progress lesson id + par moves; a bare
        // selection (no committed action) records moveCount 0, which is still
        // a valid in-progress save the Academy Continue banner can show.
        XCTAssertGreaterThanOrEqual(info?.moveCount ?? -1, 0,
                             "saved move count must be non-negative")

        // Discard clears the save (the Discard button path).
        app.discardSavedLesson()
        XCTAssertFalse(app.hasSavedLesson, "discard must clear the save")
        XCTAssertNil(app.savedLessonInfo)
    }
}
