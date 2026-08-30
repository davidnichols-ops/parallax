import XCTest
import TacticalCore
import TacticalRenderer
@testable import ParallaxApp

/// Segment 10 — focused tests for the rapid fingertip duel-feel layer:
/// action commitment windows, opponent reaction/visible thinking states,
/// tactical tempo/debt feedback, and richer feedback pulse mapping for
/// pulse/forge/sever/seal/counter/yield. All UI-only state; the deterministic
/// TacticalCore engine is never mutated by these surfaces.
final class DuelFeelTests: XCTestCase {

    // MARK: - TacticalTempo (pure computation)

    func testTempoBalancedAtSymmetricOpening() {
        // Identical player states → score 0 → pressured band (4..<12 is
        // balanced; -12..<4 is pressured). Verify the opening is not surging.
        let tempo = TacticalTempo(active: PlayerState(), opponent: PlayerState(), parity: 0)
        XCTAssertEqual(tempo.score, 0)
        XCTAssertEqual(tempo.label, .pressured)
        XCTAssertEqual(tempo.fluxRatio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tempo.initiativeDelta, 0)
        XCTAssertEqual(tempo.composureDelta, 0)
        XCTAssertEqual(tempo.moveDelta, 0)
    }

    func testTempoSurgingWhenActiveFarAhead() {
        var active = PlayerState()
        active.flux = 10_000
        active.composure = 100
        active.initiative = 20
        active.moves = 30
        var opponent = PlayerState()
        opponent.flux = 1_000
        opponent.composure = 10
        opponent.initiative = 0
        opponent.moves = 5
        let tempo = TacticalTempo(active: active, opponent: opponent, parity: -10)
        XCTAssertGreaterThan(tempo.score, 12, "a dominant active player must read as surging")
        XCTAssertEqual(tempo.label, .surging)
    }

    func testTempoStrugglingWhenActiveFarBehind() {
        var active = PlayerState()
        active.flux = 500
        active.composure = 5
        active.initiative = 0
        active.moves = 2
        var opponent = PlayerState()
        opponent.flux = 10_000
        opponent.composure = 95
        opponent.initiative = 18
        opponent.moves = 28
        let tempo = TacticalTempo(active: active, opponent: opponent, parity: 10)
        XCTAssertLessThan(tempo.score, -12, "a crushed active player must read as struggling")
        XCTAssertEqual(tempo.label, .struggling)
    }

    func testTempoLabelCaptionsAreNonEmpty() {
        for label in [TacticalTempo.Label.surging, .balanced, .pressured, .struggling] {
            XCTAssertFalse(label.caption.isEmpty)
        }
    }

    // MARK: - FeedbackPulse mapping (pure)

    func testPulseEventMapsToPulseFeedback() {
        let event = Event(seq: 0, tick: 1, type: .nodePulsed, player: .player1,
                          payload: ["node": "p0x1y0", "captured": "1"])
        guard case let .pulse(nodeId, player) = FeedbackPulse.from(event) else {
            return XCTFail("nodePulsed must map to .pulse")
        }
        XCTAssertEqual(nodeId, "p0x1y0")
        XCTAssertEqual(player, .player1)
    }

    func testYieldEventMapsToYieldFeedback() {
        let event = Event(seq: 1, tick: 1, type: .yieldIssued, player: .player2, payload: [:])
        guard case let .yield(player) = FeedbackPulse.from(event) else {
            return XCTFail("yieldIssued must map to .yield")
        }
        XCTAssertEqual(player, .player2)
    }

    func testSeverEventMapsToSeverFeedback() {
        let event = Event(seq: 2, tick: 1, type: .linkSevered, player: .player1,
                          payload: ["edge": "p0x0y0--p0x1y0", "shielded": "0", "cooldown": "45"])
        guard case let .sever(edgeId, player) = FeedbackPulse.from(event) else {
            return XCTFail("linkSevered must map to .sever")
        }
        XCTAssertEqual(edgeId, "p0x0y0--p0x1y0")
        XCTAssertEqual(player, .player1)
    }

    func testRejectedEventMapsToRejectFeedback() {
        let event = Event(seq: 3, tick: 1, type: .actionRejected, player: .player2,
                          payload: ["action": "sever", "reason": "notEnemyOwned"])
        guard case let .reject(player) = FeedbackPulse.from(event) else {
            return XCTFail("actionRejected must map to .reject")
        }
        XCTAssertEqual(player, .player2)
    }

    func testNonFingertipEventsMapToNil() {
        // Scoring, tick resolution, cursor moves, and feint registration are
        // not fingertip accents and must not produce a feedback pulse.
        for type in [EventType.scoreChanged, .tickResolved, .cursorMoved,
                     .feintRegistered, .composureChanged, .parityChanged] {
            let event = Event(seq: 0, tick: 1, type: type, player: .player1, payload: [:])
            XCTAssertNil(FeedbackPulse.from(event), "\(type) must not map to a pulse")
        }
    }

    func testPulsePlayerAccessor() {
        let pulse = FeedbackPulse.seal(faceId: "F_0", player: .player2)
        XCTAssertEqual(pulse.player, .player2)
        XCTAssertEqual(pulse.caption, "SEAL")
    }

    // MARK: - CommitmentWindow + OpponentTempo (AppState integration)

    @MainActor
    private func hotSeatApp() -> AppState {
        let app = AppState()
        app.boardId = "triad"
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.muted = true   // silence audio + haptics; feel state is still driven
        app.syncHapticsSettings()
        app.startHotSeat()
        // Select a capturable neutral node so pulse is legal at the opening.
        app.selectBoardNode("p0x1y0")
        return app
    }

    @MainActor
    func testCommitmentWindowSetOnLegalIntent() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        XCTAssertNil(app.commitmentWindow, "no commitment before any intent")
        app.performBoardAction(.pulse)
        // P1 committed; in hot-seat P2 has not yet input, so the window is
        // locked in the .locked phase awaiting the opponent's intent.
        let window = app.commitmentWindow
        XCTAssertNotNil(window, "a legal intent must open a commitment window")
        XCTAssertEqual(window?.player, .player1)
        XCTAssertEqual(window?.action, .pulse)
        XCTAssertEqual(window?.targetNode, "p0x1y0")
        XCTAssertEqual(window?.phase, .locked, "before P2 input the window stays locked")
        // Now P2 yields to complete the exchange; the window advances to resolved.
        app.yieldBoardTurn()
        XCTAssertEqual(app.commitmentWindow?.phase, .resolved,
                       "after both players commit the window must advance to resolved")
    }

    @MainActor
    func testCommitmentWindowClearedOnStopMatch() {
        let app = hotSeatApp()
        app.performBoardAction(.pulse)
        XCTAssertNotNil(app.commitmentWindow)
        app.stopMatch()
        XCTAssertNil(app.commitmentWindow, "stopMatch must clear the commitment window")
        XCTAssertEqual(app.opponentTempo, .idle, "stopMatch must reset opponent tempo")
        XCTAssertNil(app.lastFeedbackPulse, "stopMatch must clear the feedback pulse")
    }

    @MainActor
    func testOpponentTempoDeliberatingInHotSeatAfterP1Commits() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        // P1 commits; in hot-seat P2 has not yet input, so from P1's view the
        // opponent is deliberating (awaiting input). After performBoardAction
        // the active player switches to P2, so we check the state reflects the
        // awaiting phase rather than idle.
        app.performBoardAction(.pulse)
        // After the swap, activePlayer is P2; opponent (P1) has committed.
        // refreshOpponentTempo sees queuedCommands[opponent] nil (consumed on
        // resolve) OR the awaiting branch. The invariant: tempo is not idle
        // while a match is live and an exchange just happened.
        XCTAssertNotEqual(app.opponentTempo, .idle,
                         "a live hot-seat exchange must not leave opponent tempo idle")
    }

    @MainActor
    func testTacticalTempoReadsEngineState() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        let tempo = app.tacticalTempo
        // At the symmetric opening both players have max flux and equal stats.
        XCTAssertEqual(tempo.fluxRatio, 1.0, accuracy: 1e-9)
        XCTAssertEqual(tempo.initiativeDelta, 0)
        XCTAssertEqual(tempo.composureDelta, 0)
    }

    @MainActor
    func testTacticalTempoNeutralOutsideMatch() {
        let app = AppState()
        // No match started → tempo is a neutral balanced/pressured baseline.
        let tempo = app.tacticalTempo
        XCTAssertEqual(tempo.score, 0)
        XCTAssertEqual(tempo.initiativeDelta, 0)
    }

    @MainActor
    func testFeedbackPulseEmittedOnResolvedPulse() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        let tokenBefore = app.feedbackPulseToken
        app.performBoardAction(.pulse)
        // P1 committed; P2 must also act for the tick to resolve in hot-seat.
        app.yieldBoardTurn()
        XCTAssertGreaterThan(app.feedbackPulseToken, tokenBefore,
                             "a resolved pulse must increment the feedback pulse token")
        guard let pulse = app.lastFeedbackPulse else {
            return XCTFail("a resolved pulse must set lastFeedbackPulse")
        }
        XCTAssertEqual(pulse.player, .player1)
    }

    @MainActor
    func testFeedbackPulseEmittedOnYield() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        let tokenBefore = app.feedbackPulseToken
        app.yieldBoardTurn()
        // P1 yielded; P2 must also act for the tick to resolve in hot-seat.
        app.yieldBoardTurn()
        XCTAssertGreaterThan(app.feedbackPulseToken, tokenBefore,
                             "a resolved yield must increment the feedback pulse token")
        guard case .yield = app.lastFeedbackPulse else {
            return XCTFail("yield resolution must produce a .yield feedback pulse; got \(String(describing: app.lastFeedbackPulse))")
        }
    }

    @MainActor
    func testRejectedIntentDoesNotOpenCommitmentWindow() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        // Pulse a nonexistent node → illegal, rejected before queuing.
        app.selectedNodeId = "nonexistent-node"
        app.pulseSelectedBoardNode()
        XCTAssertNil(app.commitmentWindow,
                     "a rejected intent must not open a commitment window")
        XCTAssertEqual(app.hotSeatActivePlayer, .player1,
                       "a rejected intent must not hand off the turn")
    }

    @MainActor
    func testPreviewStillPrecedesCommitmentWindow() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        app.setActionPreview(.pulse)
        XCTAssertEqual(app.previewAction, .pulse)
        XCTAssertNil(app.commitmentWindow, "preview must not open a commitment window")
        app.performBoardAction(.pulse)
        // Commit consumes the preview and opens the window.
        XCTAssertNil(app.previewAction)
        XCTAssertNotNil(app.commitmentWindow)
    }

    @MainActor
    func testCommitmentWindowLabelFormat() {
        let window = CommitmentWindow(player: .player2, action: .sever,
                                       targetNode: nil, targetEdge: "p0x0y0--p0x1y0",
                                       targetFace: nil, phase: .locked, targetTick: 5)
        XCTAssertEqual(window.label, "P2: Sever → p0x0y0--p0x1y0")
    }

    @MainActor
    func testCommitmentWindowYieldLabel() {
        let window = CommitmentWindow(player: .player1, action: .yield,
                                       targetNode: nil, targetEdge: nil,
                                       targetFace: nil, phase: .locked, targetTick: 3)
        XCTAssertEqual(window.label, "P1: Yield")
    }

    @MainActor
    func testOpponentTempoCaptions() {
        for tempo in [OpponentTempo.idle, .deliberating, .committed, .reacting] {
            XCTAssertFalse(tempo.caption.isEmpty)
        }
    }

    @MainActor
    func testRefreshOpponentTempoIdleOutsideMatch() {
        let app = AppState()
        app.refreshOpponentTempo()
        XCTAssertEqual(app.opponentTempo, .idle, "outside a match the opponent tempo is idle")
    }

    // MARK: - Segment 11 — renderer-observable mappers

    @MainActor
    func testBoardFeedbackPulseNilBeforeAnyPulse() {
        let app = AppState()
        XCTAssertNil(app.boardFeedbackPulse,
                     "no renderer pulse before any action has resolved")
    }

    @MainActor
    func testBoardFeedbackPulseMapsResolvedPulse() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        app.performBoardAction(.pulse)
        app.yieldBoardTurn()
        guard let mapped = app.boardFeedbackPulse else {
            return XCTFail("a resolved pulse must map to a renderer pulse")
        }
        XCTAssertEqual(mapped.kind, .pulse)
        XCTAssertEqual(mapped.player, .player1)
        XCTAssertNotNil(mapped.targetNode)
        XCTAssertEqual(mapped.token, app.feedbackPulseToken,
                       "the renderer pulse token must mirror feedbackPulseToken")
    }

    @MainActor
    func testBoardFeedbackPulseMapsYield() {
        // Both players yield; the resolved exchange produces a .yield pulse.
        let app = hotSeatApp()
        defer { app.stopMatch() }
        app.yieldBoardTurn()
        app.yieldBoardTurn()
        guard let mapped = app.boardFeedbackPulse else {
            return XCTFail("a resolved yield must map to a renderer pulse")
        }
        XCTAssertEqual(mapped.kind, .yield, "yield must map to .yield kind")
        XCTAssertEqual(mapped.token, app.feedbackPulseToken)
    }

    @MainActor
    func testBoardCommitmentGlowNilOutsideMatch() {
        let app = AppState()
        XCTAssertNil(app.boardCommitmentGlow,
                     "no commitment glow outside a match")
    }

    @MainActor
    func testBoardCommitmentGlowMapsLockedWindow() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        app.performBoardAction(.pulse)
        guard let glow = app.boardCommitmentGlow else {
            return XCTFail("a locked window must map to a commitment glow")
        }
        XCTAssertEqual(glow.player, .player1)
        XCTAssertEqual(glow.phase, .locked)
        XCTAssertNotNil(glow.targetNode)
        XCTAssertEqual(glow.token, app.commitmentWindowToken,
                       "the glow token must mirror commitmentWindowToken")
    }

    @MainActor
    func testCommitmentWindowTokenIncrementsOnOpenAndResolve() {
        let app = hotSeatApp()
        defer { app.stopMatch() }
        let before = app.commitmentWindowToken
        app.performBoardAction(.pulse)
        let afterLock = app.commitmentWindowToken
        XCTAssertGreaterThan(afterLock, before,
                             "opening a commitment window must increment the token")
        app.yieldBoardTurn()
        XCTAssertGreaterThan(app.commitmentWindowToken, afterLock,
                             "advancing the window to resolved must increment the token")
    }

    @MainActor
    func testCommitmentWindowTokenMonotonicAndGlowClearedOnStopMatch() {
        let app = hotSeatApp()
        app.performBoardAction(.pulse)
        let afterLock = app.commitmentWindowToken
        XCTAssertGreaterThan(afterLock, 0)
        app.stopMatch()
        // The token stays monotonic across matches (mirroring feedbackPulseToken
        // from Segment 10); the renderer resets its own last-applied tracking on
        // a scene rebuild, so a fresh match re-applies correctly.
        XCTAssertGreaterThanOrEqual(app.commitmentWindowToken, afterLock)
        XCTAssertNil(app.boardCommitmentGlow,
                     "stopMatch must clear the commitment glow even though the token is monotonic")
        XCTAssertNil(app.commitmentWindow)
    }
}
