import XCTest
import TacticalCore
import TacticalBots
import TacticalPersistence
import TacticalRenderer
@testable import ParallaxApp

/// Segment 12 — AppState integration tests for the grandmaster duel persona
/// wiring. Verifies the persona is resolved on match start, the visible
/// thinking phase + replayable decision explanation are set after a bot move
/// resolves, the adaptive label is exposed, and all Segment 12 state is cleared
/// on stopMatch. All additive; the Segment 10/11 hooks and deterministic engine
/// are never mutated.
final class DuelPersonaAppTests: XCTestCase {

    /// Spin the current run loop briefly so a detached bot search task can
    /// apply its result on the main actor. Bounded so the test cannot hang.
    private func drainRunLoop(seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @MainActor
    private func skirmishApp() -> AppState {
        let app = AppState()
        app.boardId = "triad"
        app.botDifficulty = .master
        app.botPersonality = .aggressive
        app.botPersonaId = ""  // derive from personality → "striker"
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.muted = true
        app.syncHapticsSettings()
        app.startSkirmish()
        return app
    }

    @MainActor
    func testPersonaResolvedOnSkirmishStart() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        // Empty botPersonaId → derive from .aggressive → "striker".
        XCTAssertEqual(app.duelPersona.id, "striker")
        XCTAssertEqual(app.duelPersona.personality, .aggressive)
    }

    @MainActor
    func testExplicitPersonaIdOverridesPersonality() {
        let app = AppState()
        app.botDifficulty = .master
        app.botPersonality = .aggressive
        app.botPersonaId = "equilibrium"  // standoff persona, independent of personality
        app.sfxVolume = 0; app.ambienceVolume = 0; app.muted = true
        app.syncHapticsSettings()
        app.startSkirmish()
        defer { app.stopMatch() }
        XCTAssertEqual(app.duelPersona.id, "equilibrium")
        // The bot's eval personality is still .aggressive (the persona is a
        // presentation layer); only the visible flavor is "equilibrium".
        // Verified indirectly: the persona resolved to equilibrium while the
        // configured personality is aggressive.
        XCTAssertEqual(app.botPersonality, .aggressive)
    }

    @MainActor
    func testThinkingPhaseAndExplanationSetAfterBotMove() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        XCTAssertNil(app.opponentThinkingPhase, "no thinking phase before any bot move")
        XCTAssertNil(app.lastBotDecisionExplanation)
        // Drive the skirmish loop: yield as P1, advance the tick (which kicks
        // off the bot search), then drain the run loop so the detached bot
        // task can apply its result on the main actor.
        for _ in 0..<6 {
            guard app.lastBotDecisionExplanation == nil,
                  app.engine.state.gameStatus == .running else { break }
            app.yieldBoardTurn()  // queue a P1 yield via the public API
            app.advanceTick()
            drainRunLoop(seconds: 0.3)
        }
        XCTAssertNotNil(app.opponentThinkingPhase, "a resolved bot move must set the thinking phase")
        guard let exp = app.lastBotDecisionExplanation else {
            return XCTFail("a resolved bot move must set the structured explanation")
        }
        XCTAssertFalse(exp.voiceLine.isEmpty)
        XCTAssertFalse(exp.reasoning.isEmpty)
        // The thinking phase must be one of the authored phases.
        XCTAssertNotNil(ThinkingPhase(rawValue: app.opponentThinkingPhase!.rawValue))
    }

    @MainActor
    func testSegment12StateClearedOnStopMatch() {
        let app = skirmishApp()
        // Force some bot state to exist, then stop.
        app.yieldBoardTurn()
        app.advanceTick()
        drainRunLoop(seconds: 0.3)
        app.stopMatch()
        XCTAssertNil(app.opponentThinkingPhase, "stopMatch must clear the thinking phase")
        XCTAssertNil(app.lastBotDecisionExplanation, "stopMatch must clear the decision explanation")
    }

    @MainActor
    func testAdaptiveLabelHoldingOutsideMatch() {
        let app = AppState()
        XCTAssertEqual(app.opponentAdaptation, .holding, "no bot outside a match → .holding")
    }

    @MainActor
    func testAdaptiveLabelExposedDuringMatch() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        // master tier has zero noise → adaptation is always .holding.
        XCTAssertEqual(app.opponentAdaptation, .holding)
    }

    @MainActor
    func testDeliberationLineNilBeforeBotMove() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        XCTAssertNil(app.opponentDeliberationLine, "no deliberation line before a bot move resolves")
    }

    @MainActor
    func testDeliberationLineSetAfterBotMove() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        for _ in 0..<6 {
            guard app.opponentDeliberationLine == nil,
                  app.engine.state.gameStatus == .running else { break }
            app.yieldBoardTurn()
            app.advanceTick()
            drainRunLoop(seconds: 0.3)
        }
        XCTAssertNotNil(app.opponentDeliberationLine, "a resolved bot move must expose a deliberation line")
        XCTAssertFalse(app.opponentDeliberationLine!.isEmpty)
    }

    @MainActor
    func testPersonaPersistsThroughPreferences() {
        let app = AppState()
        app.botPersonaId = "architect"
        app.savePreferences()
        // Reload preferences into a fresh app.
        let reloaded = AppState()
        XCTAssertEqual(reloaded.botPersonaId, "architect",
                       "botPersonaId must round-trip through persisted preferences")
        // Restore defaults so this test doesn't leak into other tests.
        var defaults = PersistenceManager.Preferences()
        defaults.botPersonaId = ""
        try? app.persistence.savePreferences(defaults)
    }

    @MainActor
    func testOldPreferencesWithoutPersonaIdStillLoad() {
        // Backward compatibility: a prefs JSON written by an older app version
        // (no botPersonaId key) must still decode, falling back to the default
        // empty persona id, and must NOT wipe other saved fields.
        let pm = PersistenceManager()
        var oldPrefs = PersistenceManager.Preferences()
        oldPrefs.tickRate = 3.5
        oldPrefs.botDifficulty = "grandmaster"
        oldPrefs.botPersonality = "standoff"
        // Encode WITHOUT the botPersonaId key by stripping it from the JSON.
        let data = try! JSONEncoder().encode(oldPrefs)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "botPersonaId")
        let strippedData = try! JSONSerialization.data(withJSONObject: json)
        // Write to the real prefs path and reload.
        let prefsURL = pm.preferencesFile
        try? strippedData.write(to: prefsURL, options: .atomic)
        let loaded = pm.loadPreferences()
        XCTAssertEqual(loaded.botPersonaId, "", "missing botPersonaId must fall back to empty default")
        XCTAssertEqual(loaded.tickRate, 3.5, "other fields must survive the upgrade")
        XCTAssertEqual(loaded.botDifficulty, "grandmaster")
        XCTAssertEqual(loaded.botPersonality, "standoff")
        // Restore defaults so this test doesn't leak into other tests.
        try? pm.savePreferences(PersistenceManager.Preferences())
    }
}
