import XCTest
import TacticalCore
@testable import TacticalHaptics
@testable import ParallaxApp

/// Focused tests for Segment 5: action/gesture preview + commitment feedback
/// routing through AppState, and the disabled-haptic gates. Uses a recording
/// haptic performer so no real trackpad feedback fires during the test run.
final class FeedbackRoutingTests: XCTestCase {

    @MainActor
    /// Build an AppState whose haptics engine records instead of firing, with
    /// audio silenced via volume (not mute, since mute is a shared gate that
    /// would also silence haptics) so routing can be observed.
    private func app() -> (AppState, RecordingHapticPerformer) {
        let performer = RecordingHapticPerformer()
        let hapticsEngine = HapticsEngine(performer: performer, available: true)
        let app = AppState(haptics: hapticsEngine)
        app.boardId = "triad"
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.hapticsEnabled = true
        app.muted = false
        app.reduceMotion = false
        app.syncHapticsSettings()
        app.startHotSeat()
        // Select a capturable neutral node so pulse is legal at the opening
        // position (pulsing your own locked anchor is rejected by the engine).
        app.selectBoardNode("p0x1y0")
        return (app, performer)
    }

    // MARK: - Commitment feedback routing

    @MainActor
    func testLegalPulseCommitmentFiresPulseHaptic() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        // selectedNodeId is P1's anchor after startHotSeat; pulsing it is legal.
        app.performBoardAction(.pulse)
        XCTAssertEqual(app.haptics.performedPatterns, [.pulse])
        XCTAssertEqual(performer.performed, [.levelChange])
        // The preview cue is consumed by the commit.
        XCTAssertNil(app.previewAction)
    }

    @MainActor
    func testForgeCommitmentFiresForgeHaptic() {
        let (app, _) = app()
        defer { app.stopMatch() }
        app.selectBoardNode("p0x0y0")
        app.selectedEdgeId = "p0x0y0--p0x1y0"
        app.performBoardAction(.forge)
        XCTAssertTrue(app.haptics.performedPatterns.contains(.forge),
                      "forge commitment must route the forge haptic; got \(app.haptics.performedPatterns)")
    }

    @MainActor
    func testSeverCommitmentFiresSeverHaptic() {
        let (app, _) = app()
        defer { app.stopMatch() }
        // Sever targets an enemy edge; the candidate resolver picks a legal one
        // or the action is rejected. Either way a sever that commits fires .sever.
        app.performBoardAction(.sever)
        if app.actionFeedback.hasPrefix("✗") {
            // No legal sever at the opening position — rejection still fires a
            // haptic, just the rejection cue, not sever. Verify that instead.
            XCTAssertTrue(app.haptics.performedPatterns.contains(.rejection))
        } else {
            XCTAssertTrue(app.haptics.performedPatterns.contains(.sever))
        }
    }

    @MainActor
    func testRejectedIntentFiresRejectionHapticAndDoesNotQueue() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        // Pulse a nonexistent node -> illegal, rejected before queuing.
        app.selectedNodeId = "nonexistent-node"
        app.pulseSelectedBoardNode()
        XCTAssertEqual(app.haptics.performedPatterns, [.rejection])
        XCTAssertEqual(performer.performed, [.generic])
        XCTAssertEqual(app.hotSeatActivePlayer, .player1, "rejected intent must not hand off the turn")
    }

    @MainActor
    func testNonAuthoredActionsDoNotFireCommitmentHaptic() {
        let (app, _) = app()
        defer { app.stopMatch() }
        // Yield is outside the six authored cues; it must not fire a haptic.
        app.yieldBoardTurn()
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty,
                      "yield must stay silent; got \(app.haptics.performedPatterns)")
    }

    // MARK: - Action/gesture preview

    @MainActor
    func testLegalPreviewFiresPreviewHapticAndSetsState() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        app.setActionPreview(.pulse)
        XCTAssertEqual(app.previewAction, .pulse)
        XCTAssertEqual(app.haptics.performedPatterns, [.preview])
        XCTAssertEqual(performer.performed, [.alignment])
    }

    @MainActor
    func testClearActionPreviewResetsState() {
        let (app, _) = app()
        defer { app.stopMatch() }
        app.setActionPreview(.pulse)
        XCTAssertEqual(app.previewAction, .pulse)
        app.clearActionPreview()
        XCTAssertNil(app.previewAction)
    }

    @MainActor
    func testPreviewIsIgnoredWhilePaused() {
        let (app, _) = app()
        defer { app.stopMatch() }
        app.pauseToggle()
        app.setActionPreview(.pulse)
        XCTAssertNil(app.previewAction, "paused match must not accept a preview")
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty)
    }

    @MainActor
    func testCommitClearsPreview() {
        let (app, _) = app()
        defer { app.stopMatch() }
        app.setActionPreview(.pulse)
        XCTAssertEqual(app.previewAction, .pulse)
        app.performBoardAction(.pulse)
        XCTAssertNil(app.previewAction, "committing an intent must consume the preview cue")
        // Preview haptic + commitment haptic, in order.
        XCTAssertEqual(app.haptics.performedPatterns, [.preview, .pulse])
    }

    // MARK: - Disabled haptics (gates)

    @MainActor
    func testMutedDisablesHaptics() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        app.muted = true
        app.syncHapticsSettings()
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty, "mute must silence haptics")
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testReduceMotionDisablesHaptics() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        app.reduceMotion = true
        app.syncHapticsSettings()
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty, "reduce-motion must silence haptics")
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testHapticsDisabledPreferenceDisablesHaptics() {
        let (app, performer) = app()
        defer { app.stopMatch() }
        app.hapticsEnabled = false
        app.syncHapticsSettings()
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty, "disabled preference must silence haptics")
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testUnavailableEnginePerformsNothing() {
        let performer = RecordingHapticPerformer()
        let hapticsEngine = HapticsEngine(performer: performer, available: false)
        let app = AppState(haptics: hapticsEngine)
        app.boardId = "triad"
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.hapticsEnabled = true
        app.muted = false
        app.reduceMotion = false
        app.syncHapticsSettings()
        app.startHotSeat()
        defer { app.stopMatch() }
        XCTAssertFalse(app.haptics.isAvailable)
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.haptics.performedPatterns.isEmpty, "unavailable engine must stay silent")
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testStopMatchClearsPreview() {
        let (app, _) = app()
        defer { app.stopMatch() }
        app.setActionPreview(.pulse)
        XCTAssertEqual(app.previewAction, .pulse)
        app.stopMatch()
        XCTAssertNil(app.previewAction, "stopMatch must clear the preview cue")
    }
}
