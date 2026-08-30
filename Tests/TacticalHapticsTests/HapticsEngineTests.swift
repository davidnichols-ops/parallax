import XCTest
import AppKit
@testable import TacticalHaptics

final class HapticsEngineTests: XCTestCase {

    @MainActor
    private func engine(available: Bool = true) -> (HapticsEngine, RecordingHapticPerformer) {
        let performer = RecordingHapticPerformer()
        let engine = HapticsEngine(performer: performer, available: available)
        engine.enabled = true
        engine.muted = false
        engine.reduceMotion = false
        return (engine, performer)
    }

    @MainActor
    func testPlaysAllAuthoredPatternsWhenEnabled() {
        let (engine, performer) = engine()
        for pattern in HapticsEngine.HapticPattern.allCases {
            engine.play(pattern)
        }
        XCTAssertEqual(engine.performedPatterns, HapticsEngine.HapticPattern.allCases)
        XCTAssertEqual(performer.performed.count, HapticsEngine.HapticPattern.allCases.count)
    }

    @MainActor
    func testDisabledByUserPreferencePerformsNothing() {
        let (engine, performer) = engine()
        engine.enabled = false
        for pattern in HapticsEngine.HapticPattern.allCases { engine.play(pattern) }
        XCTAssertTrue(engine.performedPatterns.isEmpty)
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testMutedPerformsNothing() {
        let (engine, performer) = engine()
        engine.muted = true
        for pattern in HapticsEngine.HapticPattern.allCases { engine.play(pattern) }
        XCTAssertTrue(engine.performedPatterns.isEmpty)
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testReduceMotionPerformsNothing() {
        let (engine, performer) = engine()
        engine.reduceMotion = true
        for pattern in HapticsEngine.HapticPattern.allCases { engine.play(pattern) }
        XCTAssertTrue(engine.performedPatterns.isEmpty)
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testUnavailablePerformsNothing() {
        let (engine, performer) = engine(available: false)
        XCTAssertFalse(engine.isAvailable)
        for pattern in HapticsEngine.HapticPattern.allCases { engine.play(pattern) }
        XCTAssertTrue(engine.performedPatterns.isEmpty)
        XCTAssertTrue(performer.performed.isEmpty)
    }

    @MainActor
    func testPatternRoutingMapsToSystemPatterns() {
        let (engine, performer) = engine()
        // The six authored fingertip cues + auxiliary cues, mapped to the three
        // bounded NSHapticFeedbackManager patterns.
        let expectations: [HapticsEngine.HapticPattern: NSHapticFeedbackManager.FeedbackPattern] = [
            .pulse: .levelChange, .victory: .levelChange,
            .forge: .alignment, .seal: .alignment, .preview: .alignment,
            .sever: .generic, .counter: .generic, .rejection: .generic
        ]
        for (pattern, expected) in expectations {
            performer.reset()
            engine.resetLog()
            engine.play(pattern)
            XCTAssertEqual(performer.performed, [expected], "\(pattern) routed to wrong system pattern")
            XCTAssertEqual(engine.performedPatterns, [pattern])
        }
    }

    @MainActor
    func testReEnablingResumesPlayback() {
        let (engine, performer) = engine()
        engine.muted = true
        engine.play(.pulse)
        XCTAssertTrue(performer.performed.isEmpty)
        engine.muted = false
        engine.play(.pulse)
        XCTAssertEqual(performer.performed, [.levelChange])
        XCTAssertEqual(engine.performedPatterns, [.pulse])
    }

    @MainActor
    func testProductionInitIsSafeOnAnyHost() {
        // The production engine must never crash on a headless/trackpad-less
        // host. isAvailable may be true (the performer no-ops without a
        // trackpad), but play() must remain a safe no-op when gated.
        let engine = HapticsEngine()
        engine.muted = true
        engine.play(.victory)
        XCTAssertTrue(engine.performedPatterns.isEmpty)
    }
}
