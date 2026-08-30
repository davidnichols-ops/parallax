import XCTest
import SwiftUI
import TacticalCore
import TacticalPersistence
@testable import TacticalHaptics
@testable import ParallaxApp

/// Segment 15 — Academy UI progress surfacing tests.
///
/// Verifies that Segment 14's persisted training progress and in-progress
/// lesson save/resume are correctly surfaced in the Academy UI and round-trip
/// through AppState. Five categories:
///
/// 1. **TrainingView/Academy UI mapping** — the view mounts, the progress
///    summary reflects `trainingProgress`, completed-lesson checkmarks and
///    best-moves readouts derive from AppState, and authored AX identifiers
///    are present when the AX tree materializes.
/// 2. **Continue/discard behavior** — a saved in-progress lesson surfaces a
///    `savedLessonInfo` projection; `resumeSavedLesson()` restores the
///    engine + move count and navigates to the match screen; `discardSaved
///    Lesson()` clears the save without touching completed-lesson progress.
/// 3. **Progress display** — completing a lesson through the real flow
///    updates `trainingProgress` (isCompleted + bestMoves) and the derived
///    `completedLessonCount`.
/// 4. **Persistence round-trip through AppState** — progress written by one
///    AppState instance is loaded by a fresh instance sharing the same
///    persistence manager (simulates app restart). Lesson save state
///    round-trips the same way.
/// 5. **Existing UI harness regression** — the existing training start +
///    completion + menu-return flow still works through the rewritten view.
final class AcademyProgressTests: XCTestCase {

    /// Build a silenced AppState backed by a recording haptic performer and
    /// an isolated persistence manager rooted at a unique temp directory, so
    /// tests never pollute the user's real App Support state.
    @MainActor
    private func makeApp(persistence: PersistenceManager? = nil) -> AppState {
        let performer = RecordingHapticPerformer()
        let engine = HapticsEngine(performer: performer, available: true)
        let pm = persistence
            ?? PersistenceManager(appName: "parallax-seg15-\(UUID().uuidString)")
        let app = AppState(haptics: engine, persistence: pm)
        app.boardId = "triad"
        app.muted = true
        app.audio.muted = true
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.syncHapticsSettings()
        return app
    }

    /// The first lesson's reference solution: select p0x1y0 and pulse. The
    /// training flow auto-yields P2 so the tick resolves immediately.
    @MainActor
    private func completeFirstLesson(_ app: AppState) {
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        XCTAssertFalse(app.trainingComplete)
        app.selectBoardNode("p0x1y0")
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.trainingComplete,
                      "lesson 1 should complete via pulse: \(app.actionFeedback)")
    }

    // MARK: - 1. TrainingView / Academy UI mapping

    /// The TrainingView mounts without crashing and the AppState exposes the
    /// Segment 15 derived properties (savedLessonInfo, completedLessonCount,
    /// totalLessonCount) used by the view.
    @MainActor
    func testTrainingViewMountsAndExposesDerivedState() {
        let app = makeApp()
        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }

        XCTAssertNotNil(host.contentView, "TrainingView should mount a content view")
        XCTAssertEqual(app.totalLessonCount, TrainingCatalog.lessons.count)
        XCTAssertEqual(app.completedLessonCount, 0, "no lessons completed yet")
        XCTAssertNil(app.savedLessonInfo, "no saved lesson yet")
    }

    /// The progress summary derives from `trainingProgress`. After recording a
    /// completion directly, the count reflects it. This verifies the
    /// AppState → TrainingView mapping without depending on the AX tree.
    @MainActor
    func testProgressSummaryReflectsTrainingProgress() {
        let app = makeApp()
        XCTAssertEqual(app.completedLessonCount, 0)

        // Record a completion directly through the persistence layer (the
        // same path AppState.recordLessonCompletion uses internally).
        var progress = app.trainingProgress
        progress.recordCompletion(lessonId: TrainingCatalog.lessons.first!.id, moves: 1)
        try? app.persistence.saveTrainingProgress(progress)
        app.trainingProgress = progress

        XCTAssertEqual(app.completedLessonCount, 1)
        XCTAssertTrue(app.trainingProgress.isCompleted(TrainingCatalog.lessons.first!.id))
        XCTAssertEqual(app.trainingProgress.bestMoves(for: TrainingCatalog.lessons.first!.id), 1)
    }

    /// When the AX tree materializes (process is AX-trusted), the rewritten
    /// TrainingView exposes the new Segment 15 identifiers. Skipped otherwise
    /// (headless `swift test` cannot materialize SwiftUI semantic AX).
    @MainActor
    func testAuthoredSegment15IdentifiersExposedWhenTrusted() throws {
        let app = makeApp()
        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)). Grant "
            + "Accessibility to the test runner to exercise AX inspection.")

        let ids = host.accessibilityIdentifiers()
        // Segment 15 additions.
        XCTAssertTrue(ids.contains("training.progressSummary"),
                      "missing training.progressSummary; ids: \(ids)")
        XCTAssertTrue(ids.contains("training.detail.bestMoves"),
                      "missing training.detail.bestMoves; ids: \(ids)")
        // Existing identifiers preserved by the rewrite.
        XCTAssertTrue(ids.contains("training.start"),
                      "missing training.start; ids: \(ids)")
        XCTAssertTrue(ids.contains("training.back"),
                      "missing training.back; ids: \(ids)")
        XCTAssertTrue(ids.contains("training.detail.back"),
                      "missing training.detail.back; ids: \(ids)")
        // Each lesson row keeps its identifier.
        for lesson in TrainingCatalog.lessons {
            XCTAssertTrue(ids.contains("training.lesson.\(lesson.id)"),
                          "missing training.lesson.\(lesson.id); ids: \(ids)")
        }
    }

    /// When a saved lesson exists and the AX tree materializes, the Continue
    /// and Discard identifiers are exposed. Skipped otherwise.
    @MainActor
    func testContinueAndDiscardIdentifiersExposedWhenSavedAndTrusted() throws {
        let app = makeApp()
        // Plant a saved in-progress lesson by starting one and stopping
        // (stopMatch saves in-progress state).
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        app.selectBoardNode("p0x1y0")  // make a move-ish selection (no tick yet)
        app.stopMatch()
        XCTAssertTrue(app.hasSavedLesson, "stopMatch should save the in-progress lesson")

        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }

        try XCTSkipUnless(host.axTreeMaterialized,
            "SwiftUI AX tree not materialized — process is not AX-trusted "
            + "(AXIsProcessTrusted=\(host.accessibilityTrusted)).")
        let ids = host.accessibilityIdentifiers()
        XCTAssertTrue(ids.contains("training.continue"),
                      "missing training.continue; ids: \(ids)")
        XCTAssertTrue(ids.contains("training.discard"),
                      "missing training.discard; ids: \(ids)")
    }

    // MARK: - 2. Continue / discard behavior

    /// `savedLessonInfo` projects the saved lesson's title, move count, and
    /// par so the Academy banner can render without touching persistence.
    @MainActor
    func testSavedLessonInfoProjectsTitleMoveCountAndPar() throws {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        // Make one actual move so the move count is non-zero.
        app.selectBoardNode("p0x1y0")
        app.performBoardAction(.pulse)  // completes the lesson (par=1)
        // A completed lesson clears the save, so plant an in-progress save
        // for a different lesson by starting and stopping mid-way.
        let second = TrainingCatalog.lessons[1]
        app.startTrainingLesson(second)
        app.stopMatch()
        XCTAssertTrue(app.hasSavedLesson)
        let info = try XCTUnwrap(app.savedLessonInfo)
        XCTAssertEqual(info.lessonId, second.id)
        XCTAssertEqual(info.title, second.title)
        XCTAssertEqual(info.parMoves, second.parMoves)
        XCTAssertEqual(info.moveCount, 0, "no moves made before stop")
    }

    /// `resumeSavedLesson()` restores the engine, move count, lesson metadata,
    /// and navigates to the match screen. The save is cleared after resume.
    @MainActor
    func testResumeSavedLessonRestoresEngineAndNavigatesToMatch() throws {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        app.stopMatch()
        XCTAssertTrue(app.hasSavedLesson)

        XCTAssertTrue(app.resumeSavedLesson(), "resume should succeed")
        XCTAssertEqual(app.screen, .skirmish, "resume navigates to the match screen")
        XCTAssertEqual(app.currentLesson?.id, first.id)
        XCTAssertEqual(app.trainingLessonTitle, first.title)
        XCTAssertEqual(app.trainingParMoves, first.parMoves)
        XCTAssertFalse(app.trainingComplete, "resumed lesson is not complete")
        // The save is cleared after resume so a fresh stopMatch writes a new one.
        XCTAssertFalse(app.hasSavedLesson, "save should be cleared after resume")
    }

    /// `discardSavedLesson()` clears the save without affecting completed-
    /// lesson progress. This is the non-destructive contract.
    @MainActor
    func testDiscardSavedLessonIsNonDestructiveToCompletedProgress() {
        let app = makeApp()
        // Record a completed lesson so we can verify discard doesn't touch it.
        var progress = app.trainingProgress
        progress.recordCompletion(lessonId: TrainingCatalog.lessons.first!.id, moves: 1)
        try? app.persistence.saveTrainingProgress(progress)
        app.trainingProgress = progress
        XCTAssertTrue(app.trainingProgress.isCompleted(TrainingCatalog.lessons.first!.id))

        // Plant a saved in-progress lesson.
        let second = TrainingCatalog.lessons[1]
        app.startTrainingLesson(second)
        app.stopMatch()
        XCTAssertTrue(app.hasSavedLesson)

        // Discard it.
        app.discardSavedLesson()
        XCTAssertFalse(app.hasSavedLesson, "discard clears the save")
        XCTAssertNil(app.savedLessonInfo, "no projection after discard")

        // Completed-lesson progress is untouched.
        XCTAssertTrue(app.trainingProgress.isCompleted(TrainingCatalog.lessons.first!.id),
                      "discard must not clear completed-lesson progress")
        XCTAssertEqual(app.trainingProgress.bestMoves(for: TrainingCatalog.lessons.first!.id), 1,
                      "discard must not change best moves")
        XCTAssertEqual(app.completedLessonCount, 1,
                      "discard must not change the completed count")
    }

    /// Starting a new lesson while a save exists replaces the save
    /// (non-destructive to completed progress). This verifies the
    /// "replace" behavior is clear: the old save is overwritten.
    @MainActor
    func testStartingNewLessonReplacesSavedLesson() {
        let app = makeApp()
        // Plant a save for lesson 1.
        app.startTrainingLesson(TrainingCatalog.lessons[0])
        app.stopMatch()
        let firstInfo = app.savedLessonInfo
        XCTAssertEqual(firstInfo?.lessonId, TrainingCatalog.lessons[0].id)

        // Start lesson 2 and stop — the save should now reference lesson 2.
        app.startTrainingLesson(TrainingCatalog.lessons[1])
        app.stopMatch()
        let secondInfo = app.savedLessonInfo
        XCTAssertEqual(secondInfo?.lessonId, TrainingCatalog.lessons[1].id,
                       "starting a new lesson replaces the saved lesson id")
    }

    // MARK: - 3. Progress display after lesson completion

    /// Completing a lesson through the real flow (select + pulse) updates
    /// `trainingProgress` with isCompleted + bestMoves and the derived count.
    @MainActor
    func testCompletingLessonUpdatesTrainingProgress() {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!
        completeFirstLesson(app)

        XCTAssertTrue(app.trainingProgress.isCompleted(first.id),
                      "completion should be recorded in trainingProgress")
        XCTAssertEqual(app.trainingProgress.bestMoves(for: first.id), first.parMoves,
                       "best moves should equal par on first completion")
        XCTAssertEqual(app.completedLessonCount, 1)
        // The save is cleared on completion (the lesson is done).
        XCTAssertFalse(app.hasSavedLesson)
    }

    /// Re-completing a lesson keeps the best (lowest) move count. This is
    /// the Segment 14 `recordCompletion` contract surfaced through AppState.
    @MainActor
    func testRecompletingLessonKeepsBestMoves() {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!

        // First completion at par (1 move).
        completeFirstLesson(app)
        XCTAssertEqual(app.trainingProgress.bestMoves(for: first.id), 1)

        // Record a worse completion directly (simulates a practice run that
        // took more moves — the real flow always completes at par for lesson 1,
        // so we exercise the keeper logic through the persistence path).
        var progress = app.trainingProgress
        progress.recordCompletion(lessonId: first.id, moves: 3)
        app.trainingProgress = progress
        XCTAssertEqual(app.trainingProgress.bestMoves(for: first.id), 1,
                       "best moves should remain the minimum (1), not 3")
    }

    // MARK: - 4. Persistence round-trip through AppState

    /// Progress written by one AppState instance is loaded by a fresh instance
    /// sharing the same persistence manager (simulates app restart).
    @MainActor
    func testTrainingProgressSurvivesAppStateRestart() {
        let pm = PersistenceManager(appName: "parallax-seg15-rt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pm.appSupportDir) }

        let app1 = makeApp(persistence: pm)
        completeFirstLesson(app1)
        XCTAssertTrue(app1.trainingProgress.isCompleted(TrainingCatalog.lessons.first!.id))

        // Simulate app restart: a fresh AppState with the same persistence.
        let app2 = makeApp(persistence: pm)
        XCTAssertTrue(app2.trainingProgress.isCompleted(TrainingCatalog.lessons.first!.id),
                      "progress should survive restart")
        XCTAssertEqual(app2.trainingProgress.bestMoves(for: TrainingCatalog.lessons.first!.id), 1,
                      "best moves should survive restart")
        XCTAssertEqual(app2.completedLessonCount, 1)
    }

    /// A saved in-progress lesson survives AppState restart and can be
    /// resumed by the fresh instance. This is the full save/resume round-trip.
    @MainActor
    func testSavedLessonSurvivesAppStateRestartAndResumes() {
        let pm = PersistenceManager(appName: "parallax-seg15-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pm.appSupportDir) }

        let app1 = makeApp(persistence: pm)
        let first = TrainingCatalog.lessons.first!
        app1.startTrainingLesson(first)
        app1.stopMatch()
        XCTAssertTrue(app1.hasSavedLesson)

        // Simulate app restart.
        let app2 = makeApp(persistence: pm)
        XCTAssertTrue(app2.hasSavedLesson, "save should survive restart")
        let info = app2.savedLessonInfo
        XCTAssertEqual(info?.lessonId, first.id)
        XCTAssertEqual(info?.title, first.title)

        // Resume on the fresh instance.
        XCTAssertTrue(app2.resumeSavedLesson())
        XCTAssertEqual(app2.screen, .skirmish)
        XCTAssertEqual(app2.currentLesson?.id, first.id)
        XCTAssertFalse(app2.trainingComplete)
    }

    /// An empty/missing progress file loads gracefully (graceful degradation —
    /// the Academy never blocks on a corrupt or missing save).
    @MainActor
    func testEmptyProgressLoadsGracefully() {
        let pm = PersistenceManager(appName: "parallax-seg15-empty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pm.appSupportDir) }

        let app = makeApp(persistence: pm)
        XCTAssertEqual(app.completedLessonCount, 0)
        XCTAssertEqual(app.trainingProgress.completedLessons.count, 0)
        XCTAssertFalse(app.hasSavedLesson)
        XCTAssertNil(app.savedLessonInfo)
    }

    // MARK: - 5. Existing UI harness regression

    /// The rewritten TrainingView still launches a lesson through the
    /// `training.start` identifier path, exactly as the Segment 7 harness
    /// expects. This guards against the rewrite breaking the existing flow.
    @MainActor
    func testTrainingStartStillLaunchesLessonThroughRewrittenView() throws {
        let app = makeApp()
        app.showTraining()
        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }

        let first = try XCTUnwrap(TrainingCatalog.lessons.first)
        host.press(identifier: "training.start") { app.startTrainingLesson(first) }
        XCTAssertEqual(app.screen, .skirmish)
        XCTAssertEqual(app.currentLesson?.id, first.id)
        XCTAssertFalse(app.trainingComplete)
    }

    /// The full lesson completion + menu-return flow still works through the
    /// rewritten view. This is the Segment 7 regression scenario, verified
    /// against the Segment 15 view + progress surfacing.
    @MainActor
    func testLessonCompletionAndMenuReturnThroughRewrittenView() {
        let app = makeApp()
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)

        XCTAssertFalse(app.trainingComplete)
        app.selectBoardNode("p0x1y0")
        app.performBoardAction(.pulse)
        XCTAssertTrue(app.trainingComplete,
                      "lesson 1 should complete via pulse: \(app.actionFeedback)")
        XCTAssertEqual(app.trainingMoveCount, first.parMoves)

        // Completion should now be reflected in progress.
        XCTAssertTrue(app.trainingProgress.isCompleted(first.id))
        XCTAssertEqual(app.completedLessonCount, 1)

        // The completion overlay's Menu button returns to the menu.
        let host = UITestHost(root: MatchView(app: app), app: app)
        host.mount()
        defer { host.close() }
        host.press(identifier: "lesson.menu") { app.showMenu() }
        XCTAssertEqual(app.screen, .menu)
    }

    /// The Back to Menu button in the sidebar still returns to the menu.
    @MainActor
    func testSidebarBackToMenuStillReturnsToMenu() {
        let app = makeApp()
        app.showTraining()
        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }

        host.press(identifier: "training.back") { app.showMenu() }
        XCTAssertEqual(app.screen, .menu)
    }
}
