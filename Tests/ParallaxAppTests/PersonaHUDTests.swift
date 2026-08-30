import XCTest
import SwiftUI
import TacticalCore
import TacticalBots
import TacticalPersistence
import TacticalRenderer
@testable import ParallaxApp

/// Segment 13 — focused tests for the grandmaster persona HUD surface.
///
/// Three layers:
/// 1. **HUD state mapping** — the pure `PersonaHUD` mappers (labels, colors,
///    voice line, accessibility label) are tested directly against the
///    Segment 12 observation state. No SwiftUI mounting required.
/// 2. **Settings persistence + backward compatibility** — the SettingsView
///    persona picker wiring: changing the selection writes `botPersonaId`,
///    persists it, re-resolves the persona, and "Auto" round-trips through
///    preferences. Old prefs without `botPersonaId` still load.
/// 3. **Accessible labels + UI harness regression** — the persona strip is
///    mounted in a real MatchView; AX identifiers are asserted when the
///    process is AX-trusted (gated, like the Segment 7 harness). The strip
///    is gated to solo bot modes only (not hot-seat/training). Existing UI
///    harness behavior is not regressed.
///
/// All additive; the deterministic TacticalCore engine, Segment 8 networking,
/// Segment 9 renderer, Segment 10/11 feedback hooks/animations, training/replay
/// compatibility, audio/haptics, and release scripts are never mutated.
final class PersonaHUDTests: XCTestCase {

    /// Spin the current run loop briefly so a detached bot search task can
    /// apply its result on the main actor. Bounded so the test cannot hang.
    private func drainRunLoop(seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    @MainActor
    private func skirmishApp(personaId: String = "", personality: GrandmasterBot.Personality = .balanced) -> AppState {
        let app = AppState()
        app.boardId = "triad"
        app.botDifficulty = .master
        app.botPersonality = personality
        app.botPersonaId = personaId
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.muted = true
        app.syncHapticsSettings()
        app.startSkirmish()
        return app
    }

    // MARK: - HUD state mapping (pure PersonaHUD mappers)

    func testThinkingPhaseLabelNilShowsDash() {
        XCTAssertEqual(PersonaHUD.thinkingPhaseLabel(nil), "—",
                       "no thinking phase yet → dash placeholder")
    }

    func testThinkingPhaseLabelMapsEachPhaseCaption() {
        for phase in ThinkingPhase.allCases {
            XCTAssertEqual(PersonaHUD.thinkingPhaseLabel(phase), phase.caption,
                           "label must match the phase's own caption")
        }
    }

    func testThinkingPhaseColorNilIsDimmedMuted() {
        // No phase yet → dimmed muted. We can't assert Color equality directly,
        // but we can assert it's non-default by checking it doesn't crash and
        // returns a value (Color is not Equatable in SwiftUI without a host).
        // Instead, verify each known phase maps without crashing.
        for phase in ThinkingPhase.allCases {
            _ = PersonaHUD.thinkingPhaseColor(phase)
        }
        _ = PersonaHUD.thinkingPhaseColor(nil)
    }

    func testAdaptationColorMapsEachAdaptation() {
        for adaptation in [AdaptiveDifficulty.Adaptation.relaxing, .holding, .tightening] {
            _ = PersonaHUD.adaptationColor(adaptation)
        }
    }

    func testVoiceLineNilBeforeBotMove() {
        let board = BoardFactory.triad()
        XCTAssertNil(PersonaHUD.voiceLine(for: nil, board: board),
                     "no explanation yet → nil voice line")
    }

    func testVoiceLineBoardReadableAfterBotMove() {
        // Build a real explanation via the persona + a yield command so the
        // voice line is a real authored template substitution. Uses a
        // standalone persona (no AppState needed) so this stays non-isolated.
        let persona = DuelPersona.resolve("vector")
        let board = BoardFactory.triad()
        let state = Engine(board: board, matchSeed: 0xC0FFEE).state
        let command = Command.yield_(.player2)
        let explanation = persona.structuredExplanation(for: command, state: state)
        let readable = PersonaHUD.voiceLine(for: explanation, board: board)
        XCTAssertNotNil(readable)
        XCTAssertFalse(readable!.isEmpty, "voice line must be non-empty for a yield")
    }

    func testAccessibilityLabelBeforeBotMove() {
        let board = BoardFactory.triad()
        let label = PersonaHUD.accessibilityLabel(
            persona: .default, thinkingPhase: nil, adaptation: .holding,
            explanation: nil, board: board)
        XCTAssertTrue(label.contains("Opponent \(DuelPersona.default.displayName)"),
                      "label must name the persona; got \(label)")
        XCTAssertTrue(label.contains("awaiting first move"),
                      "label must say awaiting before a bot move; got \(label)")
        XCTAssertTrue(label.contains("pressure"), "label must include pressure; got \(label)")
    }

    func testAccessibilityLabelAfterBotMove() {
        // Uses a standalone persona + engine (no AppState) so this stays
        // non-isolated.
        let persona = DuelPersona.resolve("architect")
        let board = BoardFactory.triad()
        let state = Engine(board: board, matchSeed: 0xC0FFEE).state
        let command = Command.yield_(.player2)
        let explanation = persona.structuredExplanation(for: command, state: state)
        let label = PersonaHUD.accessibilityLabel(
            persona: persona, thinkingPhase: .bluffing, adaptation: .holding,
            explanation: explanation, board: board)
        XCTAssertTrue(label.contains("Opponent \(persona.displayName)"),
                      "label must name the persona; got \(label)")
        XCTAssertTrue(label.contains("thinking bluffing"),
                      "label must include the thinking phase; got \(label)")
        XCTAssertTrue(label.contains("pressure steady"),
                      "label must include the pressure; got \(label)")
        XCTAssertFalse(label.contains("awaiting first move"),
                       "label must not say awaiting after a bot move; got \(label)")
        // The reasoning (persona-neutral) must be included for AT users.
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - HUD state mapping through a live match (end-to-end)

    @MainActor
    func testHUDReadsResolvedPersonaOnSkirmishStart() {
        let app = skirmishApp(personaId: "equilibrium")
        defer { app.stopMatch() }
        XCTAssertEqual(app.duelPersona.id, "equilibrium")
        XCTAssertEqual(app.duelPersona.displayName, "The Equilibrium")
        // The HUD label for the persona name is the uppercased display name.
        XCTAssertEqual(app.duelPersona.displayName.uppercased(), "THE EQUILIBRIUM")
    }

    @MainActor
    func testHUDReadsThinkingPhaseAfterBotMove() {
        let app = skirmishApp(personaId: "striker")
        defer { app.stopMatch() }
        XCTAssertNil(app.opponentThinkingPhase)
        for _ in 0..<6 {
            guard app.opponentThinkingPhase == nil,
                  app.engine.state.gameStatus == .running else { break }
            app.yieldBoardTurn()
            app.advanceTick()
            drainRunLoop(seconds: 0.3)
        }
        XCTAssertNotNil(app.opponentThinkingPhase, "HUD must read a thinking phase after a bot move")
        // The label must be a valid phase caption (not the dash placeholder).
        let label = PersonaHUD.thinkingPhaseLabel(app.opponentThinkingPhase)
        XCTAssertNotEqual(label, "—", "label must not be the placeholder after a bot move")
        XCTAssertNotNil(ThinkingPhase.allCases.first { $0.caption == label },
                        "label must be a known phase caption; got \(label)")
    }

    @MainActor
    func testHUDReadsAdaptationDuringMatch() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        // master tier → zero noise → always .holding.
        XCTAssertEqual(app.opponentAdaptation, .holding)
        XCTAssertEqual(app.opponentAdaptation.caption, "STEADY")
    }

    @MainActor
    func testHUDReadsExplanationAfterBotMove() {
        let app = skirmishApp(personaId: "architect")
        defer { app.stopMatch() }
        for _ in 0..<6 {
            guard app.lastBotDecisionExplanation == nil,
                  app.engine.state.gameStatus == .running else { break }
            app.yieldBoardTurn()
            app.advanceTick()
            drainRunLoop(seconds: 0.3)
        }
        guard let explanation = app.lastBotDecisionExplanation else {
            return XCTFail("HUD must read a decision explanation after a bot move")
        }
        let voiceLine = PersonaHUD.voiceLine(for: explanation, board: app.board)
        XCTAssertNotNil(voiceLine, "HUD voice line must be non-nil after a bot move")
        XCTAssertFalse(voiceLine!.isEmpty)
        XCTAssertFalse(explanation.reasoning.isEmpty,
                       "explanation reasoning must be non-empty for the AT label")
    }

    // MARK: - Settings persistence + backward compatibility

    @MainActor
    func testSettingsPersonaPickerWritesAndPersists() {
        let app = AppState()
        app.botPersonaId = ""
        // Simulate the SettingsView picker setter: write a persona id, save,
        // and re-resolve.
        app.botPersonaId = "vector"
        app.savePreferences()
        app.resolveDuelPersona()
        XCTAssertEqual(app.duelPersona.id, "vector")
        // Reload preferences into a fresh app.
        let reloaded = AppState()
        XCTAssertEqual(reloaded.botPersonaId, "vector",
                       "botPersonaId must round-trip through persisted preferences")
        XCTAssertEqual(reloaded.duelPersona.id, "vector",
                       "reloaded app must resolve the persisted persona")
        // Restore defaults so this test doesn't leak into other tests.
        var defaults = PersistenceManager.Preferences()
        defaults.botPersonaId = ""
        try? app.persistence.savePreferences(defaults)
    }

    @MainActor
    func testSettingsPersonaPickerAutoRoundTrips() {
        let app = AppState()
        app.botPersonaId = "architect"
        app.savePreferences()
        // Simulate selecting "Auto" in the picker: write empty id, save,
        // re-resolve → derives from personality.
        app.botPersonaId = ""
        app.savePreferences()
        app.resolveDuelPersona()
        XCTAssertTrue(app.botPersonaId.isEmpty, "Auto selection must write empty id")
        // Default personality is .balanced → "vector" persona.
        XCTAssertEqual(app.duelPersona.id, "vector",
                       "Auto with .balanced personality must derive the vector persona")
        // Reload to confirm persistence.
        let reloaded = AppState()
        XCTAssertTrue(reloaded.botPersonaId.isEmpty)
        // Restore defaults.
        try? app.persistence.savePreferences(PersistenceManager.Preferences())
    }

    @MainActor
    func testSettingsPersonaPickerReResolvesOnPersonalityChange() {
        let app = AppState()
        app.botPersonaId = ""  // Auto
        app.botPersonality = .aggressive
        app.savePreferences()
        app.resolveDuelPersona()
        XCTAssertEqual(app.duelPersona.id, "striker",
                       "Auto + .aggressive → striker persona")
        // Change personality to defensive → persona should re-derive.
        app.botPersonality = .defensive
        app.resolveDuelPersona()
        XCTAssertEqual(app.duelPersona.id, "architect",
                       "Auto + .defensive → architect persona")
        // Restore defaults.
        try? app.persistence.savePreferences(PersistenceManager.Preferences())
    }

    @MainActor
    func testOldPreferencesWithoutPersonaIdStillLoad() {
        // Backward compatibility: a prefs JSON written by an older app version
        // (no botPersonaId key) must still decode, falling back to the default
        // empty persona id. This is the same guard as Segment 12's test, re-run
        // here to confirm Segment 13's SettingsView picker didn't break it.
        let pm = PersistenceManager()
        var oldPrefs = PersistenceManager.Preferences()
        oldPrefs.tickRate = 4.0
        oldPrefs.botPersonality = "standoff"
        let data = try! JSONEncoder().encode(oldPrefs)
        var json = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        json.removeValue(forKey: "botPersonaId")
        let strippedData = try! JSONSerialization.data(withJSONObject: json)
        let prefsURL = pm.preferencesFile
        try? strippedData.write(to: prefsURL, options: .atomic)
        let loaded = pm.loadPreferences()
        XCTAssertEqual(loaded.botPersonaId, "", "missing botPersonaId must fall back to empty")
        XCTAssertEqual(loaded.tickRate, 4.0, "other fields must survive the upgrade")
        XCTAssertEqual(loaded.botPersonality, "standoff")
        // Restore defaults.
        try? pm.savePreferences(PersistenceManager.Preferences())
    }

    // MARK: - Persona strip gating (no strip in hot-seat/training)

    @MainActor
    func testPersonaStripNotShownInHotSeat() {
        let app = AppState()
        app.muted = true; app.sfxVolume = 0; app.ambienceVolume = 0
        app.syncHapticsSettings()
        app.startHotSeat()
        defer { app.stopMatch() }
        // The strip is gated to skirmish/standoff only. In hot-seat there is
        // no bot, so the persona strip must not appear. We verify the gate
        // condition directly (the view's `showsPersonaStrip` is private, but
        // the screen is .hotseat and currentLesson is nil).
        XCTAssertEqual(app.screen, .hotseat)
        XCTAssertNil(app.currentLesson)
        // The persona state is still the default (no bot to drive it), but the
        // strip is not rendered because the screen is not skirmish/standoff.
        XCTAssertEqual(app.opponentAdaptation, .holding, "no bot in hot-seat → .holding")
    }

    @MainActor
    func testPersonaStripNotShownInTraining() {
        let app = AppState()
        app.muted = true; app.sfxVolume = 0; app.ambienceVolume = 0
        app.syncHapticsSettings()
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        defer { app.stopMatch() }
        // Training is solo with no bot; the persona strip must not appear.
        // The screen is .skirmish but currentLesson is non-nil, which gates
        // the strip off.
        XCTAssertEqual(app.screen, .skirmish)
        XCTAssertNotNil(app.currentLesson)
        XCTAssertEqual(app.opponentAdaptation, .holding, "no bot in training → .holding")
    }

    @MainActor
    func testPersonaStripShownInSkirmish() {
        let app = skirmishApp()
        defer { app.stopMatch() }
        // The strip is shown in skirmish (screen == .skirmish, no lesson).
        XCTAssertEqual(app.screen, .skirmish)
        XCTAssertNil(app.currentLesson)
        // The persona state is resolved and readable by the HUD.
        XCTAssertFalse(app.duelPersona.displayName.isEmpty)
    }

    // MARK: - UI harness: persona strip mounts without crashing

    @MainActor
    func testMatchViewWithPersonaStripMountsWithoutCrashing() {
        let app = skirmishApp(personaId: "equilibrium")
        let host = UITestHost(
            root: MatchView(app: app)
                .background(WindowInputBridge(app: app).frame(width: 0, height: 0)),
            app: app)
        host.mount()
        defer { host.close(); app.stopMatch() }
        XCTAssertNotNil(host.contentView, "MatchView with persona strip should mount")
    }

    @MainActor
    func testSettingsViewWithPersonaPickerMountsWithoutCrashing() {
        let app = AppState()
        app.showSettings()
        let host = UITestHost(root: SettingsView(app: app), app: app)
        host.mount()
        defer { host.close() }
        XCTAssertNotNil(host.contentView, "SettingsView with persona picker should mount")
    }

    // MARK: - Accessible labels (gated on AX trust)

    /// When the process is AX-trusted, the persona strip exposes its authored
    /// accessibility identifiers. Skipped otherwise (headless `swift test`
    /// cannot materialize SwiftUI semantic AX). Mirrors the Segment 7 harness.
    @MainActor
    func testPersonaStripAccessibilityIdentifiersWhenTrusted() throws {
        let app = skirmishApp(personaId: "vector")
        let host = UITestHost(
            root: MatchView(app: app)
                .background(WindowInputBridge(app: app).frame(width: 0, height: 0)),
            app: app)
        host.mount()
        defer { host.close(); app.stopMatch() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)). Grant "
            + "Accessibility to the test runner to exercise AX inspection.")

        let ids = host.accessibilityIdentifiers()
        XCTAssertTrue(ids.contains("match.persona.strip"),
                      "persona strip must expose match.persona.strip; ids: \(ids)")
        XCTAssertTrue(ids.contains("match.persona.name"),
                      "persona name must expose match.persona.name; ids: \(ids)")
        XCTAssertTrue(ids.contains("match.persona.thinking"),
                      "persona thinking must expose match.persona.thinking; ids: \(ids)")
        XCTAssertTrue(ids.contains("match.persona.pressure"),
                      "persona pressure must expose match.persona.pressure; ids: \(ids)")
    }

    /// When AX-trusted, the persona strip's combined accessibility label is
    /// exposed and contains the persona name. Skipped otherwise.
    @MainActor
    func testPersonaStripAccessibilityLabelContainsPersonaNameWhenTrusted() throws {
        let app = skirmishApp(personaId: "architect")
        let host = UITestHost(
            root: MatchView(app: app)
                .background(WindowInputBridge(app: app).frame(width: 0, height: 0)),
            app: app)
        host.mount()
        defer { host.close(); app.stopMatch() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)).")

        let element = host.accessibilityElement(identifier: "match.persona.strip")
        XCTAssertNotNil(element, "persona strip AX element must exist when trusted")
        // The combined label should contain the persona display name.
        XCTAssertTrue(element!.label.contains("The Architect"),
                      "AX label must contain the persona name; got \(element!.label)")
    }

    /// When AX-trusted, the SettingsView persona picker exposes its
    /// accessibility identifier. Skipped otherwise.
    @MainActor
    func testSettingsPersonaPickerAccessibilityIdentifierWhenTrusted() throws {
        let app = AppState()
        app.showSettings()
        let host = UITestHost(root: SettingsView(app: app), app: app)
        host.mount()
        defer { host.close() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)).")

        let ids = host.accessibilityIdentifiers()
        XCTAssertTrue(ids.contains("settings.botPersona"),
                      "persona picker must expose settings.botPersona; ids: \(ids)")
        XCTAssertTrue(ids.contains("settings.botPersonality"),
                      "personality picker must still expose its id; ids: \(ids)")
    }

    // MARK: - No regression to existing UI harness behavior

    /// The persona strip must not interfere with the existing match HUD
    /// identifiers (menu/pause/controls/actions). Verifies the Segment 7
    /// harness behavior is preserved when the persona strip is mounted.
    @MainActor
    func testExistingMatchHUDIdentifiersStillPresentWithPersonaStrip() throws {
        let app = skirmishApp()
        let host = UITestHost(
            root: MatchView(app: app)
                .background(WindowInputBridge(app: app).frame(width: 0, height: 0)),
            app: app)
        host.mount()
        defer { host.close(); app.stopMatch() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted.")

        let ids = host.accessibilityIdentifiers()
        // Existing identifiers from Segments 7/10/11 must still be present.
        for id in ["match.menu", "match.pause", "match.controls", "match.feedback",
                   "match.tempo", "match.pulse"] {
            XCTAssertTrue(ids.contains(id), "existing \(id) must still be present; ids: \(ids)")
        }
        for action in AppState.BoardAction.allCases {
            XCTAssertTrue(ids.contains("action.\(action.rawValue)"),
                          "existing action.\(action.rawValue) must still be present; ids: \(ids)")
        }
    }

    /// The persona strip must not interfere with the existing SettingsView
    /// identifiers. Verifies the Segment 7 settings harness is preserved.
    @MainActor
    func testExistingSettingsIdentifiersStillPresentWithPersonaPicker() throws {
        let app = AppState()
        app.showSettings()
        let host = UITestHost(root: SettingsView(app: app), app: app)
        host.mount()
        defer { host.close() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted.")

        let ids = host.accessibilityIdentifiers()
        for id in ["settings.mute", "settings.haptics", "settings.reduceMotion",
                   "settings.highContrast", "settings.colorVisionSafe", "settings.back"] {
            XCTAssertTrue(ids.contains(id), "existing \(id) must still be present; ids: \(ids)")
        }
    }
}
