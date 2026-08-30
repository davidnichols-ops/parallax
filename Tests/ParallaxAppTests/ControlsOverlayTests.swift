import AppKit
import XCTest
import TacticalCore
import TacticalPersistence
@testable import TacticalHaptics
@testable import TacticalRenderer
@testable import ParallaxApp

/// Segment 18 — controls overlay polish verification.
///
/// These tests verify that the camera reset/orbit/pan/zoom affordances added
/// in Segment 18 are present, wired, and do not regress the SmokeQA paths:
///
/// 1. **Controls overlay content (deterministic)** — the pure
///    `ControlsOverlay` constants (camera hint label, camera help rows)
///    cover orbit, pan, zoom, and reset so a player can discover the camera
///    gestures from the Controls sheet without trial-and-error.
/// 2. **Camera reset button wiring (deterministic)** — `AppState.resetCamera()`
///    increments `cameraResetToken` (the binding `BoardView` observes to call
///    `resetInteractiveCamera()`), does not mutate engine state, and is safe
///    to call repeatedly and off-match. The console button's fallback path
///    (used when AX is unavailable) routes through the same method.
/// 3. **Console button presence (AX-gated)** — when the SwiftUI AX tree
///    materializes, the match console exposes the `match.resetCamera` button
///    and the `match.camera.hint` label so the camera controls are obvious in
///    the live app, not only in the Controls sheet.
///
/// The existing `SmokeQATests` camera orbit/pan/zoom/reset tests
/// (`testRightDragOrbitsCameraWithinClampedRange`,
/// `testOptionShiftDragPansCameraTarget`, `testScrollWheelZoomsCameraDistance`,
/// `testResetCameraRestoresDefaults`) are not duplicated here; they are run
/// as a regression suite to confirm the Segment 18 console/sheet additions
/// did not alter the renderer's camera math or input handling.
final class ControlsOverlayTests: XCTestCase {

    /// Silenced AppState backed by a recording haptic performer and an
    /// isolated persistence manager so controls tests never touch the user's
    /// real App Support state.
    @MainActor
    private func makeApp() -> AppState {
        let performer = RecordingHapticPerformer()
        let engine = HapticsEngine(performer: performer, available: true)
        let pm = PersistenceManager(appName: "parallax-seg18-\(UUID().uuidString)")
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

    // MARK: - 1. Controls overlay content (deterministic, no mounting)

    /// The compact camera hint label shown in the console mentions all three
    /// mouse gestures (orbit, pan, zoom) so a player sees them at a glance
    /// without opening the Controls sheet.
    func testCameraHintLabelCoversOrbitPanZoom() {
        let label = ControlsOverlay.cameraHintLabel
        XCTAssertTrue(label.localizedCaseInsensitiveContains("orbit"),
                      "camera hint must mention orbit: \(label)")
        XCTAssertTrue(label.localizedCaseInsensitiveContains("pan"),
                      "camera hint must mention pan: \(label)")
        XCTAssertTrue(label.localizedCaseInsensitiveContains("zoom"),
                      "camera hint must mention zoom: \(label)")
        XCTAssertFalse(label.isEmpty, "camera hint must not be empty")
    }

    /// The Controls sheet Camera section heading and summary are non-empty so
    /// the section renders with content, not a blank divider.
    func testCameraSectionHeadingAndSummaryAreNonEmpty() {
        XCTAssertFalse(ControlsOverlay.cameraSectionHeading.isEmpty,
                       "camera section heading must not be empty")
        XCTAssertFalse(ControlsOverlay.cameraSectionSummary.isEmpty,
                       "camera section summary must not be empty")
    }

    /// The camera help rows cover all four affordances (orbit, pan, zoom,
    /// reset) so the Controls sheet is a complete reference, not a partial
    /// one. Each row has a non-empty key and detail.
    func testCameraHelpRowsCoverOrbitPanZoomReset() {
        let rows = ControlsOverlay.cameraHelpRows
        XCTAssertGreaterThanOrEqual(rows.count, 4,
                                    "camera help must cover orbit, pan, zoom, reset")
        let joined = rows.map { "\($0.key) \($0.detail)" }.joined(separator: " ")
            .lowercased()
        for term in ["orbit", "pan", "zoom", "reset"] {
            XCTAssertTrue(joined.contains(term),
                          "camera help rows must mention \(term): \(joined)")
        }
        for row in rows {
            XCTAssertFalse(row.key.isEmpty, "camera help row key must not be empty")
            XCTAssertFalse(row.detail.isEmpty, "camera help row detail must not be empty")
        }
    }

    /// The camera help rows' keys are unique so `ForEach(_, id: \.key)` in the
    /// controls sheet does not collide or drop rows.
    func testCameraHelpRowKeysAreUnique() {
        let keys = ControlsOverlay.cameraHelpRows.map(\.key)
        XCTAssertEqual(Set(keys).count, keys.count,
                       "camera help row keys must be unique: \(keys)")
    }

    // MARK: - 2. Camera reset button wiring (deterministic)

    /// `AppState.resetCamera()` increments `cameraResetToken`, which is the
    /// binding `BoardView` observes to call `resetInteractiveCamera()`. This
    /// is the exact wiring the console "Reset View" button uses.
    @MainActor
    func testResetCameraIncrementsToken() {
        let app = makeApp()
        let before = app.cameraResetToken
        app.resetCamera()
        XCTAssertEqual(app.cameraResetToken, before &+ 1,
                       "resetCamera must increment the token by 1")
    }

    /// Repeated calls to `resetCamera()` keep incrementing the token without
    /// crashing (wrapping addition), so a player can reset the camera any
    /// number of times.
    @MainActor
    func testResetCameraIsSafeToCallRepeatedly() {
        let app = makeApp()
        let before = app.cameraResetToken
        for _ in 0..<10 { app.resetCamera() }
        XCTAssertEqual(app.cameraResetToken, before &+ 10,
                       "resetCamera must increment the token 10 times")
    }

    /// `resetCamera()` does not mutate engine state — it is a camera-only
    /// affordance, not a game action. The canonical snapshot hash must be
    /// unchanged.
    @MainActor
    func testResetCameraDoesNotMutateEngineState() {
        let app = makeApp()
        app.startHotSeat()
        let before = CanonicalEncoding.snapshotHash(app.engine.state.snapshot())
        app.resetCamera()
        app.resetCamera()
        XCTAssertEqual(CanonicalEncoding.snapshotHash(app.engine.state.snapshot()), before,
                       "resetCamera must not mutate engine state")
    }

    /// `resetCamera()` is safe to call when not on a match screen (e.g. from
    /// the menu) — it increments the token but does not crash. The console
    /// button is only mounted on match screens, but the AppState method is
    /// public and should be defensive.
    @MainActor
    func testResetCameraSafeOffMatchScreen() {
        let app = makeApp()
        XCTAssertEqual(app.screen, .menu, "app should start on the menu screen")
        let before = app.cameraResetToken
        app.resetCamera()
        XCTAssertEqual(app.cameraResetToken, before &+ 1,
                       "resetCamera must still increment the token off-match")
    }

    /// The console "Reset View" button's fallback path (used when AX is
    /// unavailable, as in `swift test`) routes through `app.resetCamera()`,
    /// incrementing the token. This mirrors the `press(identifier:fallback:)`
    /// pattern used by `UIHarnessTests` and `SmokeQATests`.
    @MainActor
    func testCameraResetButtonFallbackPathIncrementsToken() {
        let host = makeMatchHost()
        defer { host.close() }
        let app = host.app
        let before = app.cameraResetToken
        host.press(identifier: "match.resetCamera") { app.resetCamera() }
        XCTAssertEqual(app.cameraResetToken, before &+ 1,
                       "Reset View button fallback must increment the token")
    }

    // MARK: - 3. Console button + hint presence (AX-gated)

    /// When the SwiftUI AX tree materializes (process is AX-trusted), the
    /// match console exposes the `match.resetCamera` button and the
    /// `match.camera.hint` label. Skipped otherwise, matching the
    /// `UIHarnessTests` AX-gated pattern.
    @MainActor
    func testCameraResetButtonAndHintPresentWhenTrusted() throws {
        let host = makeMatchHost()
        defer { host.close() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)).")

        let ids = host.accessibilityIdentifiers()
        XCTAssertTrue(ids.contains("match.resetCamera"),
                      "console must expose the Reset View button; ids: \(ids)")
        XCTAssertTrue(ids.contains("match.camera.hint"),
                      "console must expose the camera hint label; ids: \(ids)")
        // The existing match controls must still be present (no regression).
        XCTAssertTrue(ids.contains("match.menu"))
        XCTAssertTrue(ids.contains("match.pause"))
        XCTAssertTrue(ids.contains("match.controls"))
        XCTAssertTrue(ids.contains("match.feedback"))
    }

    /// When AX-trusted, pressing the Reset View button via the AX press
    /// action increments the camera reset token through the real SwiftUI
    /// binding, not just the fallback. Skipped otherwise.
    @MainActor
    func testCameraResetButtonAXPressIncrementsTokenWhenTrusted() throws {
        let host = makeMatchHost()
        defer { host.close() }
        let app = host.app

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)).")

        let before = app.cameraResetToken
        let pressed = host.pressAX(identifier: "match.resetCamera")
        XCTAssertTrue(pressed, "AX press on match.resetCamera must succeed")
        XCTAssertEqual(app.cameraResetToken, before &+ 1,
                       "AX press on Reset View must increment the token")
    }

    // MARK: - 4. No regression to SmokeQA camera paths

    /// The Segment 18 console/sheet additions are presentation-only and must
    /// not alter the renderer's camera reset behavior. This re-asserts the
    /// core invariant from `SmokeQATests.testResetCameraRestoresDefaults`:
    /// after an orbit drag, `testResetInteractiveCamera()` (the same path
    /// `cameraResetToken`'s `didSet` calls) restores the default azimuth,
    /// elevation, and clears the interacted flag.
    @MainActor
    func testResetInteractiveCameraStillRestoresDefaultsAfterOrbit() {
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
        XCTAssertTrue(board.testCameraHasInteracted,
                      "orbit drag must mark the camera as interacted")

        // Reset via the test accessor (same path as cameraResetToken didSet).
        board.testResetInteractiveCamera()
        XCTAssertFalse(board.testCameraHasInteracted,
                       "reset must clear the interacted flag")
        XCTAssertEqual(board.testCameraAzimuth, .pi * 0.06, accuracy: 0.0001,
                       "reset must restore the default azimuth")
        XCTAssertEqual(board.testCameraElevation, .pi * 0.30, accuracy: 0.0001,
                       "reset must restore the default elevation")
    }

    /// The Segment 18 camera reset button wiring (token → BoardView
    /// `didSet` → `resetInteractiveCamera()`) must actually trigger the
    /// renderer reset, not just increment a counter. After an orbit, bumping
    /// `cameraResetToken` via `app.resetCamera()` must restore the defaults
    /// in the mounted board view.
    @MainActor
    func testCameraResetTokenTriggersBoardViewReset() {
        let host = makeMatchHost()
        defer { host.close() }
        guard let board = host.findBoardView() else {
            XCTFail("BoardHostingView not mounted"); return
        }
        let app = host.app
        let windowNumber = host.window.windowNumber
        let center = NSPoint(x: board.bounds.midX, y: board.bounds.midY)

        // Orbit so the camera is off-default and interacted.
        if let down = mouseEvent(.rightMouseDown, location: center,
                                 windowNumber: windowNumber) {
            board.rightMouseDown(with: down)
        }
        if let drag = mouseEvent(.leftMouseDragged,
                                 location: NSPoint(x: center.x + 70, y: center.y + 40),
                                 windowNumber: windowNumber) {
            board.mouseDragged(with: drag)
        }
        if let up = mouseEvent(.rightMouseUp, location: center,
                               windowNumber: windowNumber) {
            board.rightMouseUp(with: up)
        }
        XCTAssertTrue(board.testCameraHasInteracted)
        let azOff = board.testCameraAzimuth

        // Drive the reset through the public AppState method (the button path).
        app.resetCamera()
        // Drain the run loop so the @Published -> @Binding -> didSet propagates.
        host.drainRunLoop(seconds: 0.1)

        XCTAssertFalse(board.testCameraHasInteracted,
                       "app.resetCamera() must clear the board's interacted flag")
        XCTAssertEqual(board.testCameraAzimuth, .pi * 0.06, accuracy: 0.0001,
                       "app.resetCamera() must restore the board's default azimuth")
        XCTAssertNotEqual(board.testCameraAzimuth, azOff,
                          "azimuth must differ from the orbited value after reset")
    }

    // MARK: - Helpers

    /// Build a synthetic mouse event of the given type at `locationInWindow`.
    private func mouseEvent(_ type: NSEvent.EventType, location: NSPoint,
                            windowNumber: Int,
                            modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: location,
                           modifierFlags: modifiers, timestamp: 0,
                           windowNumber: windowNumber, context: nil,
                           eventNumber: 0, clickCount: 1, pressure: 1.0)
    }
}
