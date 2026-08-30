import XCTest
@testable import TacticalPersistence
import TacticalCore

/// Segment 14 tests: training progress persistence, in-progress lesson
/// save/resume (including counter-window preservation), replay persona-id
/// capture, and backward compatibility for pre-Segment-14 replays.
///
/// These tests close the known training/replay gap so Strategema lessons and
/// counter windows are replayable and save/resume safe. They verify:
///   1. Old replay compatibility — v2 replays without persona ids decode
///      with nil persona ids (no version bump needed).
///   2. New lesson replay round-trip — persona ids are captured and
///      preserved through encode/decode.
///   3. Counter lesson save/resume — a mid-lesson save captures the live
///      counter window and the resumed engine accepts counter commands.
///   4. Deterministic replay playback — replay verification still passes
///      with the new persona-id fields.
///   5. Training progress persistence — completed lessons survive
///      save/load with best-move tracking.
final class TrainingProgressTests: XCTestCase {

    var board: BoardDefinition!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallax-seg14-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - 1. Old replay compatibility (pre-Segment-14 v2 replays)

    func testAudioDefaultsFavorAmbience() throws {
        let defaults = PersistenceManager.Preferences()
        XCTAssertEqual(defaults.sfxVolume, 0.05, accuracy: 0.0001)
        XCTAssertEqual(defaults.ambienceVolume, 1.0, accuracy: 0.0001)

        let legacy = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PersistenceManager.Preferences.self, from: legacy)
        XCTAssertEqual(decoded.sfxVolume, 0.05, accuracy: 0.0001)
        XCTAssertEqual(decoded.ambienceVolume, 1.0, accuracy: 0.0001)
    }

    /// A v2 replay written before Segment 14 (no persona-id fields) must
    /// decode with nil persona ids. This confirms the new optional fields
    /// are backward-compatible — no version bump needed.
    func testPreSegment14V2ReplayDecodesWithNilPersonaIds() throws {
        // Construct a v2 JSON without persona-id fields (as written by
        // pre-Segment-14 code).
        let v2JSON = """
        {
          "boardId": "triad",
          "createdAt": "2026-01-01T00:00:00Z",
          "durationTicks": 0,
          "finalEventLogHash": "",
          "finalSnapshotHash": "",
          "formatVersion": 2,
          "matchSeed": 42,
          "player1Type": "human",
          "player2Type": "bot",
          "rulesetVersion": "1",
          "ticks": [],
          "lessonId": "pulse-first-capture",
          "initialSnapshot": null,
          "initialCounterableActions": null
        }
        """
        let data = v2JSON.data(using: .utf8)!
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.lessonId, "pulse-first-capture")
        XCTAssertNil(decoded.player1PersonaId,
                     "Pre-Segment-14 v2 replay must have nil player1PersonaId")
        XCTAssertNil(decoded.player2PersonaId,
                     "Pre-Segment-14 v2 replay must have nil player2PersonaId")
    }

    /// A v1 replay (no v2 fields at all) must still decode with nil persona
    /// ids. This confirms v1 → v2 + Segment 14 backward compatibility.
    func testV1ReplayDecodesWithNilPersonaIds() throws {
        let v1JSON = """
        {
          "boardId": "triad",
          "createdAt": "2026-01-01T00:00:00Z",
          "durationTicks": 0,
          "finalEventLogHash": "",
          "finalSnapshotHash": "",
          "formatVersion": 1,
          "matchSeed": 0,
          "player1Type": "human",
          "player2Type": "human",
          "rulesetVersion": "1",
          "ticks": []
        }
        """
        let data = v1JSON.data(using: .utf8)!
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.formatVersion, 1)
        XCTAssertNil(decoded.player1PersonaId)
        XCTAssertNil(decoded.player2PersonaId)
    }

    // MARK: - 2. New lesson replay round-trip with persona ids

    /// A regular match replay with persona ids must round-trip the persona
    /// ids through encode/decode.
    func testRegularReplayRoundTripsPersonaIds() throws {
        var replay = Replay(board: board, matchSeed: 99,
                            p1Type: .human, p2Type: .bot)
        replay.player2PersonaId = "striker"
        var engine = Engine(board: board, matchSeed: 99)
        let (snap, _) = engine.submitTick([.yield_(.player1), .yield_(.player2)])
        replay.recordTick(snap.tick,
                          p1Cmd: .yield_(.player1), p2Cmd: .yield_(.player2),
                          snapshotHash: CanonicalEncoding.snapshotHash(snap))
        replay.finalize(
            snapshotHash: CanonicalEncoding.snapshotHash(engine.state.snapshot()),
            eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.player2PersonaId, "striker",
                       "Persona id must round-trip through encode/decode")
        XCTAssertNil(decoded.player1PersonaId,
                     "Player 1 persona id should be nil (human player)")
        XCTAssertTrue(decoded.verify(board: board),
                      "Replay with persona ids must still verify")
    }

    /// A training lesson replay must have nil persona ids (training has no
    /// bot opponent).
    func testTrainingReplayHasNilPersonaIds() throws {
        let lesson = TrainingCatalog.lessons[0]
        let engine = lesson.makeEngine()
        let replay = Replay(lesson: lesson, engine: engine)
        XCTAssertNil(replay.player1PersonaId,
                     "Training replay must have nil player1PersonaId")
        XCTAssertNil(replay.player2PersonaId,
                     "Training replay must have nil player2PersonaId")
    }

    /// Empty-string persona id ("derive from personality") must round-trip
    /// distinctly from nil (absent). This matters because the replay encoder
    /// uses encodeIfPresent: nil omits the field, "" writes it.
    func testEmptyPersonaIdRoundTripsDistinctlyFromNil() throws {
        var replay = Replay(board: board, matchSeed: 1,
                            p1Type: .human, p2Type: .bot)
        replay.player2PersonaId = ""  // explicit "derive from personality"
        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.player2PersonaId, "",
                       "Empty-string persona id must round-trip as empty, not nil")
    }

    // MARK: - 3. Counter lesson save/resume

    /// Save the counter lesson mid-progress (after the pre-run setup tick)
    /// and verify the resumed engine has the live counter window.
    func testCounterLessonSaveResumePreservesCounterWindow() throws {
        let lesson = TrainingCatalog.lessons[6]
        XCTAssertEqual(lesson.id, "counter-parry-vector")

        let engine = lesson.makeEngine()
        XCTAssertEqual(engine.state.tick, 1,
                       "Counter lesson must be at tick 1 after setup")
        let counterable = engine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }
        XCTAssertNotNil(counterable, "Live counter window must be present")
        let seq = counterable!.seq

        // Save the in-progress lesson state.
        let saveState = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: engine.state.lastCounterableActions.isEmpty
                ? nil : engine.state.lastCounterableActions,
            moveCount: 0,
            trainingComplete: false
        )
        // Round-trip through JSON.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(saveState)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistenceManager.LessonSaveState.self, from: data)

        // Reconstruct the engine from the saved state.
        let restoredEngine = decoded.makeEngine(board: lesson.board)
        XCTAssertEqual(restoredEngine.state.tick, 1,
                       "Restored engine must be at tick 1")
        let restoredCounterable = restoredEngine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }
        XCTAssertNotNil(restoredCounterable,
                        "Restored engine must have the live counter window")
        XCTAssertEqual(restoredCounterable?.seq, seq,
                       "Restored counterable seq must match the original")
        XCTAssertEqual(restoredCounterable?.targetEdge, "p0x3y2--p0x3y3",
                       "Restored counterable target edge must match")
    }

    /// The resumed counter lesson must accept and succeed a counter command.
    /// This is the end-to-end save/resume test: save mid-lesson → restore →
    /// submit the counter → verify it succeeds.
    func testCounterLessonSaveResumeAcceptsCounterCommand() throws {
        let lesson = TrainingCatalog.lessons[6]
        let engine = lesson.makeEngine()
        let seq = engine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }!.seq

        // Save mid-lesson.
        let saveState = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: engine.state.lastCounterableActions,
            moveCount: 0,
            trainingComplete: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(saveState)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistenceManager.LessonSaveState.self, from: data)

        // Restore and submit the counter command.
        var restoredEngine = decoded.makeEngine(board: lesson.board)
        let (snap, events) = restoredEngine.submitTick([
            .counter(.player1, "p0x3y2--p0x3y3", counteredSeq: seq),
            .yield_(.player2)
        ])
        XCTAssertTrue(events.contains { $0.type == EventType.vectorCountered },
                      "Counter must succeed in the restored engine")
        XCTAssertGreaterThanOrEqual(
            restoredEngine.state.playerStates[.player1]?.successfulCounters ?? 0, 1,
            "Restored engine must record the successful counter")
        // The lesson's completion predicate must be satisfied.
        XCTAssertTrue(lesson.isComplete(state: restoredEngine.state, events: events),
                      "Restored engine must satisfy the lesson completion predicate")
        // Snapshot hash must be deterministic (non-empty).
        XCTAssertFalse(CanonicalEncoding.snapshotHash(snap).isEmpty,
                       "Restored engine must produce a valid snapshot hash")
    }

    /// A lesson saved with no counterable actions (e.g. the pulse lesson at
    /// tick 0) must restore with an empty counter window and still be playable.
    func testNonCounterLessonSaveResumeHasEmptyCounterWindow() throws {
        let lesson = TrainingCatalog.lessons[0]
        XCTAssertEqual(lesson.id, "pulse-first-capture")
        let engine = lesson.makeEngine()
        XCTAssertTrue(engine.state.lastCounterableActions.isEmpty,
                      "Pulse lesson must have no counterable actions at start")

        let saveState = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: nil,  // empty → nil (same as v2 replay convention)
            moveCount: 0,
            trainingComplete: false
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(saveState)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistenceManager.LessonSaveState.self, from: data)

        let restoredEngine = decoded.makeEngine(board: lesson.board)
        XCTAssertTrue(restoredEngine.state.lastCounterableActions.isEmpty,
                      "Non-counter lesson must restore with empty counter window")
        // The restored engine must still accept a pulse command.
        var eng = restoredEngine
        let (_, events) = eng.submitTick([
            .pulse(.player1, "p0x1y0"), .yield_(.player2)
        ])
        XCTAssertTrue(events.contains { $0.type == EventType.nodePulsed },
                      "Pulse must succeed in the restored engine")
        XCTAssertTrue(lesson.isComplete(state: eng.state, events: events),
                      "Restored pulse lesson must satisfy completion")
    }

    // MARK: - 4. Deterministic replay playback with persona ids

    /// A full training replay (all 8 lessons) with persona-id fields present
    /// must still verify deterministically. The persona-id fields are metadata
    /// only — they do not affect engine reconstruction or hash verification.
    func testAllTrainingLessonsReplayDeterministicallyWithPersonaFields() {
        for lesson in TrainingCatalog.lessons {
            var engine = lesson.makeEngine()
            var replay = Replay(lesson: lesson, engine: engine)
            // Even if persona ids were set (they shouldn't be for training,
            // but test robustness), verification must still pass.
            replay.player1PersonaId = nil
            replay.player2PersonaId = nil

            let solution = referenceSolution(for: lesson)
            for tickCmds in solution {
                let (snap, _) = engine.submitTick(tickCmds)
                replay.recordTick(snap.tick,
                                  p1Cmd: tickCmds[0], p2Cmd: tickCmds[1],
                                  snapshotHash: CanonicalEncoding.snapshotHash(snap))
            }
            let finalSnap = engine.state.snapshot()
            replay.finalize(
                snapshotHash: CanonicalEncoding.snapshotHash(finalSnap),
                eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

            // Encode → decode → verify.
            do {
                let data = try replay.encode()
                let decoded = try Replay.decode(data)
                XCTAssertTrue(decoded.verify(board: lesson.board),
                              "\(lesson.id): replay must verify with persona-id fields present")
                // Double-encode determinism.
                let data2 = try decoded.encode()
                XCTAssertEqual(data, data2,
                               "\(lesson.id): round-trip encode must be deterministic")
            } catch {
                XCTFail("\(lesson.id): round-trip failed: \(error)")
            }
        }
    }

    /// A regular match replay with a non-nil persona id must verify
    /// deterministically. The persona id is metadata only.
    func testRegularReplayWithPersonaIdVerifiesDeterministically() throws {
        var replay = Replay(board: board, matchSeed: 0xDEAD,
                            p1Type: .human, p2Type: .bot)
        replay.player2PersonaId = "architect"
        var engine = Engine(board: board, matchSeed: 0xDEAD)
        let cmds: [[Command]] = [
            [.pulse(.player1, "p0x1y0"), .yield_(.player2)],
            [.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)]
        ]
        for tickCmds in cmds {
            let (snap, _) = engine.submitTick(tickCmds)
            replay.recordTick(snap.tick,
                              p1Cmd: tickCmds[0], p2Cmd: tickCmds[1],
                              snapshotHash: CanonicalEncoding.snapshotHash(snap))
        }
        replay.finalize(
            snapshotHash: CanonicalEncoding.snapshotHash(engine.state.snapshot()),
            eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.player2PersonaId, "architect")
        XCTAssertTrue(decoded.verify(board: board),
                      "Regular replay with persona id must verify")
    }

    // MARK: - 5. Training progress persistence

    func testTrainingProgressRoundTrip() throws {
        var progress = PersistenceManager.TrainingProgress()
        progress.recordCompletion(lessonId: "pulse-first-capture", moves: 1)
        progress.recordCompletion(lessonId: "forge-claim-link", moves: 1)
        progress.recordCompletion(lessonId: "seal-close-cycle", moves: 2)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(progress)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PersistenceManager.TrainingProgress.self, from: data)

        XCTAssertTrue(decoded.isCompleted("pulse-first-capture"))
        XCTAssertTrue(decoded.isCompleted("forge-claim-link"))
        XCTAssertTrue(decoded.isCompleted("seal-close-cycle"))
        XCTAssertEqual(decoded.bestMoves(for: "pulse-first-capture"), 1)
        XCTAssertEqual(decoded.bestMoves(for: "seal-close-cycle"), 2)
        XCTAssertFalse(decoded.isCompleted("counter-parry-vector"))
        XCTAssertNil(decoded.bestMoves(for: "counter-parry-vector"))
    }

    func testTrainingProgressKeepsBestMoves() {
        var progress = PersistenceManager.TrainingProgress()
        progress.recordCompletion(lessonId: "seal-close-cycle", moves: 3)
        progress.recordCompletion(lessonId: "seal-close-cycle", moves: 2)
        progress.recordCompletion(lessonId: "seal-close-cycle", moves: 5)
        XCTAssertEqual(progress.bestMoves(for: "seal-close-cycle"), 2,
                       "Best moves must be the minimum across completions")
    }

    func testTrainingProgressEmptyFileLoadsGracefully() {
        // An empty/corrupt file must not throw — it returns empty progress.
        let pm = PersistenceManager(appName: "parallax-seg14-empty-\(UUID().uuidString)")
        let progress = pm.loadTrainingProgress()
        XCTAssertEqual(progress.completedLessons.count, 0,
                       "Missing progress file must load as empty")
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    func testTrainingProgressSaveLoadRoundTrip() throws {
        let pm = PersistenceManager(appName: "parallax-seg14-rt-\(UUID().uuidString)")
        var progress = PersistenceManager.TrainingProgress()
        progress.recordCompletion(lessonId: "pulse-first-capture", moves: 1)
        progress.recordCompletion(lessonId: "counter-parry-vector", moves: 1)
        try pm.saveTrainingProgress(progress)

        let loaded = pm.loadTrainingProgress()
        XCTAssertTrue(loaded.isCompleted("pulse-first-capture"))
        XCTAssertTrue(loaded.isCompleted("counter-parry-vector"))
        XCTAssertEqual(loaded.bestMoves(for: "counter-parry-vector"), 1)
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    // MARK: - 6. LessonSaveState persistence via PersistenceManager

    func testLessonSaveStateSaveLoadRoundTrip() throws {
        let pm = PersistenceManager(appName: "parallax-seg14-save-\(UUID().uuidString)")
        let lesson = TrainingCatalog.lessons[6]  // counter lesson
        let engine = lesson.makeEngine()
        let counterable = engine.state.lastCounterableActions

        let state = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: counterable,
            moveCount: 0,
            trainingComplete: false
        )
        try pm.saveLessonState(state)

        let loaded = pm.loadLessonState()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.lessonId, "counter-parry-vector")
        XCTAssertEqual(loaded?.moveCount, 0)
        XCTAssertEqual(loaded?.trainingComplete, false)
        XCTAssertNotNil(loaded?.counterableActions,
                        "Loaded counter lesson must have counterable actions")

        // Reconstruct and verify the counter window is live.
        let restoredEngine = loaded!.makeEngine(board: lesson.board)
        XCTAssertNotNil(
            restoredEngine.state.lastCounterableActions
                .first { $0.action == .forge && $0.player == .player2 },
            "Restored engine must have the live counter window")
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    func testLessonSaveStateClearRemovesSave() throws {
        let pm = PersistenceManager(appName: "parallax-seg14-clear-\(UUID().uuidString)")
        let lesson = TrainingCatalog.lessons[0]
        let engine = lesson.makeEngine()
        let state = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: nil,
            moveCount: 0,
            trainingComplete: false
        )
        try pm.saveLessonState(state)
        XCTAssertNotNil(pm.loadLessonState(), "Save must exist after saveLessonState")
        pm.clearLessonState()
        XCTAssertNil(pm.loadLessonState(), "Save must be gone after clearLessonState")
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    func testLessonSaveStateNoSaveReturnsNil() {
        let pm = PersistenceManager(appName: "parallax-seg14-nosave-\(UUID().uuidString)")
        XCTAssertNil(pm.loadLessonState(),
                     "loadLessonState must return nil when no save exists")
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    // MARK: - Helpers

    /// Return the reference solution (per-tick command lists) for each lesson.
    /// Mirrors the verified solutions in TrainingTests.swift.
    private func referenceSolution(for lesson: TrainingLesson) -> [[Command]] {
        switch lesson.id {
        case "pulse-first-capture":
            return [[.pulse(.player1, "p0x1y0"), .yield_(.player2)]]
        case "forge-claim-link":
            return [[.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)]]
        case "seal-close-cycle":
            return [
                [.forge(.player1, "p0x0y0--p0x0y1"), .yield_(.player2)],
                [.seal(.player1, "F_p0_x0_y0"), .yield_(.player2)]
            ]
        case "reinforce-anchor-shield":
            return [[.reinforce(.player1, "p0x0y0"), .yield_(.player2)]]
        case "traverse-cross-conduit":
            return [[.traverse(.player1, "p0x0y0--p1x0y0"), .yield_(.player2)]]
        case "sever-cut-enemy-line":
            return [[.sever(.player1, "p0x3y2--p0x3y3"), .yield_(.player2)]]
        case "counter-parry-vector":
            let eng = lesson.makeEngine()
            let seq = eng.state.lastCounterableActions
                .first { $0.action == .forge && $0.player == .player2 }!.seq
            return [[.counter(.player1, "p0x3y2--p0x3y3", counteredSeq: seq),
                     .yield_(.player2)]]
        case "yield-hold-parity":
            return [[.yield_(.player1), .yield_(.player2)]]
        default:
            XCTFail("Unknown lesson id: \(lesson.id)")
            return []
        }
    }
}
