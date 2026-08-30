import XCTest
import SwiftUI
import TacticalCore
import TacticalBots
import TacticalPersistence
@testable import TacticalHaptics
@testable import TacticalRenderer
@testable import ParallaxApp

/// Segment 20 — deterministic screenshot artifacts for the playable match
/// surfaces that were previously only harness-tested (no PNG evidence).
///
/// The rc2 visual-QA gap (noted in the Segment 19 progress): the real app
/// could not be driven via AppleScript (no Assistive Access for `osascript`)
/// and `swift test` runs with `AXIsProcessTrusted=false`, so the SwiftUI
/// surfaces a user sees — menu, skirmish match with persona HUD, Controls
/// overlay (camera section), Academy Continue banner, and Settings persona/
/// audio controls — had no captured PNG artifacts, only AX/harness assertions.
///
/// This file closes that gap with a test-only screenshot harness that mounts
/// the **real** SwiftUI views in-process (via `UITestHost`), captures the
/// mounted `NSWindow` content view to a PNG, composites the live SceneKit
/// board snapshot on top where a board is present (Metal layers render black
/// under `bitmapImageRep`), and pixel-checks each artifact for non-blank
/// content plus a surface-specific layout/visibility assertion.
///
/// Artifacts are written to `$PARALLAX_SCREENSHOT_DIR` (or a temp directory
/// fallback) so re-runs are deterministic and the progress notes can cite
/// exact paths/sizes. No app/game behavior is changed; the only production
/// edit is the `internal` access level on `MatchView.controlsSheet` so the
/// harness can mount the real Controls overlay without AX.
final class ScreenshotArtifactTests: XCTestCase {

    /// Silenced AppState backed by a recording haptic performer and an
    /// isolated persistence manager so screenshot tests never touch the user's
    /// real App Support state.
    @MainActor
    private func makeApp() -> AppState {
        let performer = RecordingHapticPerformer()
        let engine = HapticsEngine(performer: performer, available: true)
        let pm = PersistenceManager(appName: "parallax-seg20-\(UUID().uuidString)")
        let app = AppState(haptics: engine, persistence: pm)
        app.boardId = "triad"
        app.muted = true
        app.audio.muted = true
        app.sfxVolume = 0
        app.ambienceVolume = 0
        app.syncHapticsSettings()
        return app
    }

    /// The deterministic output directory for PNG artifacts. Overridable via
    /// `PARALLAX_SCREENSHOT_DIR` so a run can land artifacts in the progress
    /// notes' work directory; defaults to a stable temp directory.
    private var screenshotDir: URL {
        if let path = ProcessInfo.processInfo.environment["PARALLAX_SCREENSHOT_DIR"],
           !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("parallax-seg20-screenshots")
    }

    /// Assert a captured report is non-blank and the PNG file exists with a
    /// non-trivial size, then print the report for the progress notes.
    private func assertNonBlank(_ report: UITestHost.ScreenshotReport,
                                named name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertTrue(report.nonBlank,
                      "\(name) screenshot must be non-blank: \(report)", file: file, line: line)
        XCTAssertGreaterThan(report.byteCount, 4_000,
                             "\(name) PNG is suspiciously small: \(report.byteCount) bytes",
                             file: file, line: line)
        let url = URL(fileURLWithPath: report.file)
        let exists = FileManager.default.fileExists(atPath: url.path)
        XCTAssertTrue(exists, "\(name) PNG not written at \(report.file)", file: file, line: line)
        print("[Segment20] \(name) → \(report.file) "
              + "(\(report.width)x\(report.height), \(report.byteCount) bytes, "
              + "bright=\(report.brightSamples) colorful=\(report.colorfulSamples) "
              + "bounds=\(report.contentBounds) board=\(report.compositedBoard))")
    }

    // MARK: - 1. Menu

    /// The main menu: left configuration panel (modes, board/opponent pickers,
    /// replay/settings buttons) + the right static 3D board preview. Captures
    /// both halves and verifies content lands in the left panel region and the
    /// right preview region (board composited from the SceneKit snapshot).
    @MainActor
    func testCaptureMenuScreenshot() throws {
        let app = makeApp()
        let host = UITestHost(root: MenuView(app: app), app: app)
        host.mount()
        defer { host.close() }
        let report = try host.captureSnapshot(named: "menu", to: screenshotDir)
        try assertNonBlank(report, named: "menu")
        // Layout: the left config panel (~358pt of 1180pt ≈ 0...0.31) and the
        // right board preview (~0.32...1.0) both carry bright content.
        let leftBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0, width: 0.31, height: 1))
        let rightBright = host.brightSamples(inNormalizedRect: CGRect(x: 0.32, y: 0, width: 0.68, height: 1))
        XCTAssertGreaterThan(leftBright, 15, "menu left panel should have visible content: \(leftBright)")
        XCTAssertGreaterThan(rightBright, 15, "menu right board preview should have visible content: \(rightBright)")
        XCTAssertTrue(report.compositedBoard, "menu preview board should be composited into the artifact")
    }

    // MARK: - 2. Skirmish match with persona HUD

    /// A solo skirmish with a named grandmaster persona so the persona HUD
    /// strip (name, thinking phase, pressure, voice line) renders under the
    /// header. Captures the full match surface with the live board composited.
    @MainActor
    func testCaptureSkirmishPersonaHUDScreenshot() throws {
        let app = makeApp()
        app.botDifficulty = .master
        app.botPersonaId = "vector"
        app.startSkirmish()
        // The persona strip is gated to skirmish/standoff with no active lesson.
        XCTAssertEqual(app.screen, .skirmish)
        XCTAssertNotNil(app.duelPersona.id, "persona should resolve for the HUD strip")
        let view = MatchView(app: app)
            .background(WindowInputBridge(app: app).frame(width: 0, height: 0))
        let host = UITestHost(root: view, app: app)
        host.mount()
        defer { host.close() }
        let report = try host.captureSnapshot(named: "skirmish-persona-hud", to: screenshotDir)
        try assertNonBlank(report, named: "skirmish-persona-hud")
        // Layout: the header + persona HUD strip occupy roughly the top 22% of
        // the match surface; it must carry visible (bright) content.
        let topBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.22))
        XCTAssertGreaterThan(topBright, 15,
                             "match header + persona HUD strip should have visible content: \(topBright)")
        XCTAssertTrue(report.compositedBoard, "skirmish board should be composited into the artifact")
    }

    // MARK: - 3. Controls overlay with camera section

    /// The Controls overlay sheet (mounted directly via `controlsSheet`, since
    /// AX cannot open the sheet in a non-trusted `swift test` process). Verifies
    /// the Camera section heading/summary/help rows render and the content
    /// spans the sheet width.
    @MainActor
    func testCaptureControlsOverlayScreenshot() throws {
        let app = makeApp()
        app.startSkirmish()
        // Mount the real Controls overlay surface (the same view the `.sheet`
        // presents in production). `controlsSheet` is `internal` for this harness.
        let sheet = MatchView(app: app).controlsSheet
        let host = UITestHost(root: sheet, app: app)
        host.mount()
        defer { host.close() }
        let report = try host.captureSnapshot(named: "controls-overlay", to: screenshotDir)
        try assertNonBlank(report, named: "controls-overlay")
        // The Controls overlay is a 620pt-wide sheet centered in the 1180pt
        // window, so bright content should appear in both the left and right
        // halves (the help rows span the sheet width).
        let leftBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0, width: 0.5, height: 1))
        let rightBright = host.brightSamples(inNormalizedRect: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        XCTAssertGreaterThan(leftBright, 15, "controls overlay left half should have content: \(leftBright)")
        XCTAssertGreaterThan(rightBright, 15, "controls overlay right half should have content: \(rightBright)")
        XCTAssertFalse(report.compositedBoard, "controls overlay has no board to composite")
    }

    // MARK: - 4. Academy progress / Continue banner

    /// The Training Academy with a saved in-progress lesson so the "Continue
    /// Lesson" banner renders in the sidebar alongside the progress summary
    /// and lesson catalog. Verifies the sidebar region carries content.
    @MainActor
    func testCaptureAcademyContinueBannerScreenshot() throws {
        let app = makeApp()
        // Start a lesson (sets currentLesson), then navigate to the Academy.
        // `showTraining()` → `stopMatch()` saves the in-progress lesson, so
        // `savedLessonInfo` projects it and the Continue banner appears.
        let first = TrainingCatalog.lessons.first!
        app.startTrainingLesson(first)
        app.showTraining()
        let info = try XCTUnwrap(app.savedLessonInfo,
                                 "a saved lesson should exist so the Continue banner renders")
        XCTAssertEqual(info.lessonId, first.id)
        let host = UITestHost(root: TrainingView(app: app), app: app)
        host.mount()
        defer { host.close() }
        let report = try host.captureSnapshot(named: "academy-continue-banner", to: screenshotDir)
        try assertNonBlank(report, named: "academy-continue-banner")
        // Layout: the catalog sidebar (~320pt of 1180pt ≈ 0...0.28) holds the
        // progress summary, Continue banner, and lesson rows.
        let sidebarBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0, width: 0.28, height: 1))
        XCTAssertGreaterThan(sidebarBright, 15,
                             "academy sidebar (progress + continue banner) should have content: \(sidebarBright)")
        XCTAssertFalse(report.compositedBoard, "academy view has no board to composite")
    }

    // MARK: - 5. Settings persona/audio controls

    /// The Settings screen with the persona picker, audio volume sliders, and
    /// accessibility toggles. Verifies the scrollable sections render with
    /// content spanning a tall vertical region.
    @MainActor
    func testCaptureSettingsScreenshot() throws {
        let app = makeApp()
        app.botPersonaId = "architect"
        app.showSettings()
        XCTAssertEqual(app.screen, .settings)
        let host = UITestHost(root: SettingsView(app: app), app: app)
        host.mount()
        defer { host.close() }
        let report = try host.captureSnapshot(named: "settings-persona-audio", to: screenshotDir)
        try assertNonBlank(report, named: "settings-persona-audio")
        // Layout: Settings is a centered scrollable column of sections; content
        // should span a tall vertical region (top and bottom thirds both carry
        // bright content).
        let topBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0, width: 1, height: 0.33))
        let bottomBright = host.brightSamples(inNormalizedRect: CGRect(x: 0, y: 0.67, width: 1, height: 0.33))
        XCTAssertGreaterThan(topBright, 15, "settings top region should have content: \(topBright)")
        XCTAssertGreaterThan(bottomBright, 10, "settings lower region should have content: \(bottomBright)")
        XCTAssertFalse(report.compositedBoard, "settings view has no board to composite")
    }
}
