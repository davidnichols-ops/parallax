import XCTest
@testable import TacticalPersistence
import TacticalCore

/// Segment 6 tests: training and replay persistence completeness and
/// determinism. Covers:
///   - Round-trip encode/decode for v2 regular and training replays
///   - Format versioning (v1 backward compatibility, v2 current)
///   - Training lesson recording and deterministic replay for all 8 lessons
///   - Counter-window state serialization (Lesson 7 pre-run tick)
///   - Backward compatibility: v1 JSON decodes as v2 with nil lesson fields
///   - PersistenceManager import accepts v1 and v2
final class ReplayPersistenceTests: XCTestCase {

    var board: BoardDefinition!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        try? BoardValidator.validate(board)
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("parallax-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(
            at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Format versioning

    func testCurrentFormatVersionIs2() {
        XCTAssertEqual(Replay.currentFormatVersion, 2)
    }

    func testRegularReplayUsesCurrentFormatVersion() {
        let replay = Replay(board: board, matchSeed: 42,
                            p1Type: .human, p2Type: .bot)
        XCTAssertEqual(replay.formatVersion, 2)
        XCTAssertNil(replay.lessonId)
        XCTAssertNil(replay.initialSnapshot)
        XCTAssertNil(replay.initialCounterableActions)
        XCTAssertFalse(replay.isTrainingReplay)
    }

    // MARK: - Round-trip: regular match

    func testRegularReplayRoundTrip() throws {
        var replay = Replay(board: board, matchSeed: 0xABCD,
                            p1Type: .human, p2Type: .bot)
        // Run a few ticks and record them.
        var engine = Engine(board: board, matchSeed: 0xABCD)
        let cmds: [[Command]] = [
            [.pulse(.player1, "p0x1y0"), .yield_(.player2)],
            [.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)],
            [.yield_(.player1), .yield_(.player2)]
        ]
        for tickCmds in cmds {
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
        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.formatVersion, 2)
        XCTAssertEqual(decoded.boardId, "triad")
        XCTAssertEqual(decoded.matchSeed, 0xABCD)
        XCTAssertEqual(decoded.ticks.count, 3)
        XCTAssertEqual(decoded.durationTicks, 3)
        XCTAssertTrue(decoded.verify(board: board),
                      "Round-tripped regular replay must verify")
    }

    // MARK: - Round-trip: training lesson (all 8)

    func testAllTrainingLessonsRecordAndReplay() {
        for lesson in TrainingCatalog.lessons {
            var engine = lesson.makeEngine()
            // Record the initial state in a v2 training replay.
            var replay = Replay(lesson: lesson, engine: engine)
            XCTAssertEqual(replay.formatVersion, 2,
                           "\(lesson.id): replay must be v2")
            XCTAssertEqual(replay.lessonId, lesson.id,
                           "\(lesson.id): lessonId must match")
            XCTAssertNotNil(replay.initialSnapshot,
                           "\(lesson.id): initialSnapshot must be captured")
            XCTAssertTrue(replay.isTrainingReplay,
                          "\(lesson.id): must be a training replay")

            // Run the reference solution (from TrainingTests).
            let solution = referenceSolution(for: lesson)
            var allEvents: [Event] = []
            for tickCmds in solution {
                let (snap, ev) = engine.submitTick(tickCmds)
                allEvents.append(contentsOf: ev)
                replay.recordTick(snap.tick,
                                  p1Cmd: tickCmds[0], p2Cmd: tickCmds[1],
                                  snapshotHash: CanonicalEncoding.snapshotHash(snap))
            }
            let finalSnap = engine.state.snapshot()
            replay.finalize(
                snapshotHash: CanonicalEncoding.snapshotHash(finalSnap),
                eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

            // The lesson must be complete.
            XCTAssertTrue(lesson.isComplete(state: engine.state, events: allEvents),
                          "\(lesson.id): reference solution must complete the lesson")

            // Round-trip and verify.
            do {
                let data = try replay.encode()
                let decoded = try Replay.decode(data)
                XCTAssertEqual(decoded.lessonId, lesson.id,
                               "\(lesson.id): decoded lessonId mismatch")
                XCTAssertNotNil(decoded.initialSnapshot,
                               "\(lesson.id): decoded initialSnapshot missing")
                XCTAssertTrue(decoded.verify(board: lesson.board),
                              "\(lesson.id): round-tripped training replay must verify")
            } catch {
                XCTFail("\(lesson.id): round-trip failed: \(error)")
            }
        }
    }

    // MARK: - Counter-window serialization (Lesson 7)

    func testCounterLessonPreservesCounterableActions() throws {
        let lesson = TrainingCatalog.lessons[6]
        XCTAssertEqual(lesson.id, "counter-parry-vector")

        let engine = lesson.makeEngine()
        // The counter lesson pre-runs tick 1: P2 forged p0x3y2--p0x3y3.
        XCTAssertEqual(engine.state.tick, 1)
        let counterable = engine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }
        XCTAssertNotNil(counterable, "Counterable forge must be live")

        let replay = Replay(lesson: lesson, engine: engine)
        // The counterable actions must be serialized.
        XCTAssertNotNil(replay.initialCounterableActions,
                        "Counter lesson must serialize counterable actions")
        XCTAssertEqual(replay.initialCounterableActions?.count, 1,
                       "Exactly one counterable action (the forge)")

        // Round-trip and check the restored engine has the counter window.
        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertNotNil(decoded.initialCounterableActions,
                        "Decoded counterable actions must be present")
        let restoredEngine = decoded.makeReplayEngine(board: lesson.board)
        let restoredCounterable = restoredEngine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }
        XCTAssertNotNil(restoredCounterable,
                        "Restored engine must have the live counter window")
        XCTAssertEqual(restoredCounterable?.seq, counterable?.seq,
                       "Restored counterable seq must match")
        XCTAssertEqual(restoredCounterable?.targetEdge, "p0x3y2--p0x3y3",
                       "Restored counterable target edge must match")
    }

    func testCounterLessonReplayAcceptsCounterCommand() throws {
        let lesson = TrainingCatalog.lessons[6]
        var engine = lesson.makeEngine()
        let counterable = engine.state.lastCounterableActions
            .first { $0.action == .forge && $0.player == .player2 }!
        let seq = counterable.seq

        var replay = Replay(lesson: lesson, engine: engine)
        // Tick 2: trainee counters the forge.
        let (snap, events) = engine.submitTick([
            .counter(.player1, "p0x3y2--p0x3y3", counteredSeq: seq),
            .yield_(.player2)
        ])
        replay.recordTick(snap.tick,
                          p1Cmd: .counter(.player1, "p0x3y2--p0x3y3", counteredSeq: seq),
                          p2Cmd: .yield_(.player2),
                          snapshotHash: CanonicalEncoding.snapshotHash(snap))
        let finalSnap = engine.state.snapshot()
        replay.finalize(
            snapshotHash: CanonicalEncoding.snapshotHash(finalSnap),
            eventLogHash: CanonicalEncoding.eventLogHash(engine.log))
        XCTAssertTrue(events.contains { $0.type == EventType.vectorCountered },
                      "Counter must succeed in the live engine")

        // Round-trip and verify — the replay must reconstruct the counter
        // window and successfully replay the counter command.
        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertTrue(decoded.verify(board: lesson.board),
                      "Counter lesson replay must verify after round-trip")
    }

    // MARK: - Backward compatibility: v1 replay decodes as v2

    func testV1ReplayDecodesAsV2WithNilLessonFields() throws {
        // Construct a v1-format JSON (no lessonId, initialSnapshot, etc.).
        let v1JSON = """
        {
          "boardId": "triad",
          "createdAt": "2026-01-01T00:00:00Z",
          "durationTicks": 1,
          "finalEventLogHash": "abc",
          "finalSnapshotHash": "def",
          "formatVersion": 1,
          "matchSeed": 42,
          "player1Type": "human",
          "player2Type": "bot",
          "rulesetVersion": "1",
          "ticks": []
        }
        """
        let data = v1JSON.data(using: .utf8)!
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.formatVersion, 1,
                       "v1 replay must keep formatVersion 1 after decode")
        XCTAssertNil(decoded.lessonId,
                     "v1 replay must have nil lessonId")
        XCTAssertNil(decoded.initialSnapshot,
                     "v1 replay must have nil initialSnapshot")
        XCTAssertNil(decoded.initialCounterableActions,
                     "v1 replay must have nil initialCounterableActions")
        XCTAssertFalse(decoded.isTrainingReplay,
                       "v1 replay must not be a training replay")
    }

    func testV1ReplayVerifiesWithFreshEngine() throws {
        // Build a real v1-style replay (formatVersion=1, no v2 fields) by
        // encoding a v2 replay and stripping the v2 fields from JSON.
        var replay = Replay(board: board, matchSeed: 99,
                            p1Type: .human, p2Type: .human)
        var engine = Engine(board: board, matchSeed: 99)
        let (snap, _) = engine.submitTick([.pulse(.player1, "p0x1y0"), .yield_(.player2)])
        replay.recordTick(snap.tick,
                          p1Cmd: .pulse(.player1, "p0x1y0"),
                          p2Cmd: .yield_(.player2),
                          snapshotHash: CanonicalEncoding.snapshotHash(snap))
        let finalSnap = engine.state.snapshot()
        replay.finalize(
            snapshotHash: CanonicalEncoding.snapshotHash(finalSnap),
            eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

        // Manually set formatVersion to 1 and strip v2 fields.
        replay.formatVersion = 1
        replay.lessonId = nil
        replay.initialSnapshot = nil
        replay.initialCounterableActions = nil

        // Encode with a standard encoder (not the custom one — we want raw
        // JSON without the v2 keys). Since our custom encoder uses
        // encodeIfPresent for the v2 fields, nil values are omitted.
        let data = try replay.encode()
        let decoded = try Replay.decode(data)
        XCTAssertEqual(decoded.formatVersion, 1)
        // A v1 replay with no initialSnapshot reconstructs from a fresh engine.
        XCTAssertTrue(decoded.verify(board: board),
                      "v1 replay must verify using fresh engine reconstruction")
    }

    // MARK: - PersistenceManager import accepts v1 and v2

    func testPersistenceManagerAcceptsV2Replay() throws {
        let pm = PersistenceManager(appName: "parallax-test-\(UUID().uuidString)")
        var replay = Replay(board: board, matchSeed: 7,
                            p1Type: .human, p2Type: .bot)
        var engine = Engine(board: board, matchSeed: 7)
        let (snap, _) = engine.submitTick([.yield_(.player1), .yield_(.player2)])
        replay.recordTick(snap.tick,
                          p1Cmd: .yield_(.player1), p2Cmd: .yield_(.player2),
                          snapshotHash: CanonicalEncoding.snapshotHash(snap))
        replay.finalize(
            snapshotHash: CanonicalEncoding.snapshotHash(engine.state.snapshot()),
            eventLogHash: CanonicalEncoding.eventLogHash(engine.log))

        let file = tempDir.appendingPathComponent("v2-replay.json")
        try replay.encode().write(to: file)
        let imported = try pm.importReplay(from: file)
        XCTAssertEqual(imported.formatVersion, 2)
        // Clean up.
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    func testPersistenceManagerAcceptsV1Replay() throws {
        let pm = PersistenceManager(appName: "parallax-test-\(UUID().uuidString)")
        // A v1 JSON with formatVersion=1.
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
        let file = tempDir.appendingPathComponent("v1-replay.json")
        try v1JSON.data(using: .utf8)!.write(to: file)
        let imported = try pm.importReplay(from: file)
        XCTAssertEqual(imported.formatVersion, 1)
        // Clean up.
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    func testPersistenceManagerRejectsUnknownFormat() throws {
        let pm = PersistenceManager(appName: "parallax-test-\(UUID().uuidString)")
        let badJSON = """
        {
          "boardId": "triad",
          "createdAt": "2026-01-01T00:00:00Z",
          "durationTicks": 0,
          "finalEventLogHash": "",
          "finalSnapshotHash": "",
          "formatVersion": 99,
          "matchSeed": 0,
          "player1Type": "human",
          "player2Type": "human",
          "rulesetVersion": "1",
          "ticks": []
        }
        """
        let file = tempDir.appendingPathComponent("bad-replay.json")
        try badJSON.data(using: .utf8)!.write(to: file)
        XCTAssertThrowsError(try pm.importReplay(from: file)) { error in
            guard case PersistenceManager.ImportError.unsupportedFormat(99) = error else {
                XCTFail("Expected unsupportedFormat(99), got \(error)")
                return
            }
        }
        // Clean up.
        try? FileManager.default.removeItem(at: pm.appSupportDir)
    }

    // MARK: - Determinism: training replay produces identical hashes

    func testTrainingReplayDeterminism() throws {
        for lesson in TrainingCatalog.lessons {
            var engine = lesson.makeEngine()
            var replay = Replay(lesson: lesson, engine: engine)
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

            // Encode twice — must produce identical bytes.
            let data1 = try replay.encode()
            let data2 = try replay.encode()
            XCTAssertEqual(data1, data2,
                           "\(lesson.id): encode must be deterministic")

            // Decode and re-encode — must produce identical bytes.
            let decoded = try Replay.decode(data1)
            let data3 = try decoded.encode()
            XCTAssertEqual(data1, data3,
                           "\(lesson.id): round-trip encode must be deterministic")
        }
    }

    // MARK: - Initial snapshot captures lesson state

    func testInitialSnapshotCapturesLessonOwnedNodes() throws {
        // Lesson 2 (forge) pre-owns p0x0y0 and p0x1y0 for P1.
        let lesson = TrainingCatalog.lessons[1]
        XCTAssertEqual(lesson.id, "forge-claim-link")
        let engine = lesson.makeEngine()
        let replay = Replay(lesson: lesson, engine: engine)
        let snap = replay.initialSnapshot!
        XCTAssertEqual(snap.nodes["p0x0y0"]?.owner, .player1,
                       "Initial snapshot must capture P1-owned p0x0y0")
        XCTAssertEqual(snap.nodes["p0x1y0"]?.owner, .player1,
                       "Initial snapshot must capture P1-owned p0x1y0")

        // Restore and check the engine state matches.
        let restored = replay.makeReplayEngine(board: lesson.board)
        XCTAssertEqual(restored.state.nodes["p0x0y0"]?.owner, .player1)
        XCTAssertEqual(restored.state.nodes["p0x1y0"]?.owner, .player1)
    }

    func testInitialSnapshotCapturesLessonSealedEdges() throws {
        // Lesson 3 (seal) pre-forges three boundary edges.
        let lesson = TrainingCatalog.lessons[2]
        XCTAssertEqual(lesson.id, "seal-close-cycle")
        let engine = lesson.makeEngine()
        let replay = Replay(lesson: lesson, engine: engine)
        let snap = replay.initialSnapshot!
        XCTAssertEqual(snap.edges["p0x0y0--p0x1y0"]?.owner, .player1, "top edge pre-forged")
        XCTAssertEqual(snap.edges["p0x1y0--p0x1y1"]?.owner, .player1, "right edge pre-forged")
        XCTAssertEqual(snap.edges["p0x0y1--p0x1y1"]?.owner, .player1, "bottom edge pre-forged")
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
