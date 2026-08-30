import Foundation
import AVFoundation
import CoreAudio
import TacticalCore

/// Original synthesized sound with a bounded graph. All graph changes and
/// playback requests share the main actor, never an audio render callback.
/// The ambience is a restrained Enterprise-era warp-room homage: deep
/// detuned fundamentals, a filtered reactor shimmer, and a slow phasing beat.
/// It is generated at runtime and contains no lifted television soundtrack.
@MainActor
public final class AudioEngine {
    private var engine: AVAudioEngine?
    private var sfxMixer: AVAudioMixerNode?
    private var ambienceMixer: AVAudioMixerNode?
    private var masterMixer: AVAudioMixerNode?
    private var ambiencePlayers: [AVAudioPlayerNode] = []
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    public private(set) var isAvailable = false

    public var sfxVolume: Float = 0.7 {
        didSet { sfxMixer?.outputVolume = sfxVolume }
    }
    public var ambienceVolume: Float = 0.3 {
        didSet { ambienceMixer?.outputVolume = ambienceVolume }
    }
    public var muted: Bool = false {
        didSet { masterMixer?.outputVolume = muted ? 0 : 1.0 }
    }

    private var started = false

    public convenience init() {
        self.init(deviceAvailable: Self.hasAudioDevice())
    }

    /// Explicit no-device construction allows the silent path to be tested.
    init(deviceAvailable: Bool) {
        // AVAudioMixerNode raises an Objective-C exception—not a recoverable
        // Swift error—when no CoreAudio output component exists. Preflight the
        // hardware before constructing any graph so headless/remote Macs still
        // run the game silently instead of crashing at launch.
        guard deviceAvailable else {
            return
        }

        let graph = AVAudioEngine()
        let sfx = AVAudioMixerNode()
        let ambience = AVAudioMixerNode()
        let master = AVAudioMixerNode()
        graph.attach(sfx)
        graph.attach(ambience)
        graph.attach(master)
        graph.connect(sfx, to: master, format: nil)
        graph.connect(ambience, to: master, format: nil)
        graph.connect(master, to: graph.mainMixerNode, format: nil)
        let mono = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        // Reuse these nodes for the entire app session. Connecting each drone
        // directly to the mixer also avoids overwriting a shared EQ input bus.
        for _ in 0..<2 {
            let drone = AVAudioPlayerNode()
            graph.attach(drone)
            graph.connect(drone, to: ambience, format: mono)
            ambiencePlayers.append(drone)
        }
        for _ in 0..<12 {
            let voice = AVAudioPlayerNode()
            graph.attach(voice)
            graph.connect(voice, to: sfx, format: mono)
            voices.append(voice)
        }
        master.outputVolume = 1.0
        sfx.outputVolume = sfxVolume
        ambience.outputVolume = ambienceVolume
        engine = graph
        sfxMixer = sfx
        ambienceMixer = ambience
        masterMixer = master
        isAvailable = true
    }

    public func start() {
        guard !started, let engine else { return }
        do {
            engine.prepare()
            try engine.start()
            started = true
            startAmbience()
        } catch {
            // Audio is optional. Preserve gameplay without sending expected
            // device failures to the launching terminal.
            started = false
        }
    }

    public func stop() {
        for drone in ambiencePlayers { drone.stop() }
        for voice in voices { voice.stop() }
        engine?.stop()
        nextVoice = 0
        started = false
    }

    // MARK: - Ambience

    private func startAmbience() {
        guard ambiencePlayers.count == 2 else { return }
        let drone1 = ambiencePlayers[0]
        let drone2 = ambiencePlayers[1]

        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let droneBuffer1 = makeDroneBuffer(frequency: 43.5, duration: 8.0, format: format)
        let droneBuffer2 = makeDroneBuffer(frequency: 44.15, duration: 8.0, format: format)

        drone1.scheduleBuffer(droneBuffer1, at: nil, options: [.loops])
        drone2.scheduleBuffer(droneBuffer2, at: nil, options: [.loops])
        drone1.play()
        drone2.play()
    }

    private func makeDroneBuffer(frequency: Float, duration: TimeInterval, format: AVAudioFormat) -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!
        for frame in 0..<Int(frameCount) {
            let t = Float(frame) / Float(format.sampleRate)
            // Slow, deliberately non-loop-obvious modulation keeps the bed
            // alive while avoiding a distracting musical pulse.
            let phase = 2 * Float.pi * frequency * t
            let beat = 0.84 + 0.16 * sinf(2 * Float.pi * 0.17 * t + frequency)
            let sub = sinf(phase * 0.5 + 0.22) * 0.34
            let fundamental = sinf(phase) * 0.72
            let harmonic = sinf(phase * 2.01 + 0.8) * 0.13
            let shimmer = sinf(2 * Float.pi * (frequency * 5.03) * t + 0.4) * 0.045
            // Deterministic pseudo-noise gives the reactor a soft air edge,
            // without the hiss of an unfiltered noise generator.
            let noise = sinf(2 * Float.pi * 137.0 * t) * sinf(2 * Float.pi * 0.71 * t) * 0.018
            channels[0][frame] = (sub + fundamental + harmonic + shimmer + noise) * beat * 0.105
        }
        return buffer
    }

    // MARK: - SFX

    /// Play a short synthesized tone for a game event.
    public func playEvent(_ type: EventType, player: Player? = nil) {
        guard started, !muted, let sfxMixer else { return }
        let (freq, duration, waveType) = eventParameters(type)
        playTone(frequency: freq, duration: duration, waveType: waveType,
                 player: player, bus: sfxMixer)
    }

    private func eventParameters(_ type: EventType) -> (Float, TimeInterval, WaveType) {
        switch type {
        case .nodePulsed:    return (440, 0.08, .sine)
        case .linkForged:    return (330, 0.12, .triangle)
        case .cycleSealed:   return (660, 0.25, .sine)
        case .linkSevered:   return (110, 0.15, .sawtooth)
        case .actionRejected: return (150, 0.05, .square)
        case .scoreChanged:  return (880, 0.15, .sine)
        case .cursorMoved:   return (220, 0.03, .sine)
        case .tickResolved:  return (80, 0.02, .sine)
        case .matchEnded:    return (523, 0.5, .triangle)
        case .conduitTraversed: return (550, 0.1, .sine)
        case .vectorCountered: return (250, 0.1, .square)
        case .yieldIssued:   return (180, 0.06, .sine)
        }
    }

    private enum WaveType { case sine, triangle, sawtooth, square }

    private func playTone(frequency: Float, duration: TimeInterval, waveType: WaveType,
                          player: Player?, bus: AVAudioMixerNode) {
        guard !voices.isEmpty else { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let frameCount = AVAudioFrameCount(duration * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)!
        buffer.frameLength = frameCount
        let channels = buffer.floatChannelData!

        let pFreq: Float = player == .player2 ? frequency * 1.5 : frequency

        for frame in 0..<Int(frameCount) {
            let t = Float(frame) / Float(format.sampleRate)
            let phase = 2 * .pi * pFreq * t
            let attack = min(1, Float(frame) / Float(format.sampleRate * 0.003))
            let envelope = attack * max(0, 1 - Float(frame) / Float(frameCount))
            let val: Float
            switch waveType {
            case .sine:     val = sinf(phase) * envelope * 0.3
            case .triangle: val = (2 / .pi) * asinf(sinf(phase)) * envelope * 0.3
            case .sawtooth: val = (2 * (pFreq * t - floor(0.5 + pFreq * t))) * envelope * 0.2
            case .square:   val = (sinf(phase) > 0 ? 1.0 : -1.0) * envelope * 0.15
            }
            channels[0][frame] = val
        }

        let playerNode = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        playerNode.stop()
        playerNode.scheduleBuffer(buffer, at: nil, options: [.interrupts])
        playerNode.play()
    }

    public enum EventType: CaseIterable, Sendable {
        case nodePulsed, linkForged, cycleSealed, linkSevered
        case actionRejected, scoreChanged, cursorMoved, tickResolved
        case matchEnded, conduitTraversed, vectorCountered
        case yieldIssued
    }

    private static func hasAudioDevice() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        return status == noErr && device != kAudioObjectUnknown
    }

    // Internal regression diagnostics: tests do not receive mutable audio nodes.
    var attachedNodeCount: Int { engine?.attachedNodes.count ?? 0 }
    var isRunning: Bool { started }
}
