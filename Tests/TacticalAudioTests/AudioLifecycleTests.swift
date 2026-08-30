import XCTest
@testable import TacticalAudio

final class AudioLifecycleTests: XCTestCase {
    @MainActor
    func testNoDeviceRemainsSafeAndSilent() {
        let audio = AudioEngine(deviceAvailable: false)
        for _ in 0..<10 {
            audio.start()
            for event in AudioEngine.EventType.allCases { audio.playEvent(event) }
            audio.stop()
        }
        XCTAssertFalse(audio.isAvailable)
        XCTAssertFalse(audio.isRunning)
        XCTAssertEqual(audio.attachedNodeCount, 0)
    }

    @MainActor
    func testRestartDoesNotGrowAudioGraph() throws {
        let audio = AudioEngine()
        guard audio.isAvailable else { throw XCTSkip("No output device on this test host") }
        audio.muted = true
        defer { audio.stop() }
        let count = audio.attachedNodeCount
        XCTAssertGreaterThan(count, 0)
        for _ in 0..<8 {
            audio.start()
            audio.start()
            XCTAssertEqual(audio.attachedNodeCount, count)
            audio.stop()
            XCTAssertFalse(audio.isRunning)
            XCTAssertEqual(audio.attachedNodeCount, count)
        }
    }

    @MainActor
    func testEventBurstUsesBoundedVoicePool() throws {
        let audio = AudioEngine()
        guard audio.isAvailable else { throw XCTSkip("No output device on this test host") }
        audio.sfxVolume = 0
        audio.ambienceVolume = 0
        audio.start()
        defer { audio.stop() }
        guard audio.isRunning else { throw XCTSkip("Output device cannot start on this test host") }
        let count = audio.attachedNodeCount
        for _ in 0..<4 {
            for event in AudioEngine.EventType.allCases {
                audio.playEvent(event)
                audio.playEvent(event, player: .player2)
            }
        }
        XCTAssertEqual(audio.attachedNodeCount, count)
    }
}
