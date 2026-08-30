import Foundation
import AppKit

/// Optional macOS trackpad haptics for the rapid fingertip strategy-duel feel.
///
/// Mirrors `TacticalAudio.AudioEngine`: a bounded, main-actor, restart-safe
/// surface that is safe when unavailable. Haptics are gated by four independent
/// conditions — any one suppresses the feedback:
///   1. `isAvailable` — the platform haptic performer is present.
///   2. `enabled` — the user opted in (default on).
///   3. `!muted` — the global mute also silences haptics.
///   4. `!reduceMotion` — the accessibility reduce-motion gate.
///
/// Haptics never change deterministic rules, the authored board, the camera,
/// or the keyboard/mouse APIs. They are a purely additive tactile channel that
/// rides alongside the existing audio + text feedback.
@MainActor
public final class HapticsEngine {

    /// The six authored commitment haptics plus the auxiliary cues. Each maps
    /// to one of the three `NSHapticFeedbackManager` patterns so the surface
    /// stays bounded and predictable.
    public enum HapticPattern: String, Sendable, CaseIterable {
        case pulse       // capture a node
        case forge       // create a link
        case sever       // cut an enemy edge
        case seal        // close a region
        case counter     // intercept an enemy vector
        case victory     // match won
        case rejection   // illegal intent denied
        case preview     // lightweight hover/focus cue before commitment

        /// The AppKit trackpad pattern this cue renders as.
        var systemPattern: NSHapticFeedbackManager.FeedbackPattern {
            switch self {
            case .pulse, .victory:    return .levelChange
            case .forge, .seal, .preview: return .alignment
            case .sever, .counter, .rejection: return .generic
            }
        }
    }

    public private(set) var isAvailable: Bool

    public var enabled: Bool = true
    public var muted: Bool = false
    public var reduceMotion: Bool = false

    /// Patterns actually performed since creation (test observable). Only
    /// appended after a performer call, so a guarded-out pattern never appears.
    public private(set) var performedPatterns: [HapticPattern] = []

    private let performer: HapticPerformer

    /// Production initializer. Probes the AppKit performer; on headless or
    /// unsupported hosts the engine stays safe and silent.
    public init() {
        let system = SystemHapticPerformer()
        self.performer = system
        self.isAvailable = system.isReady
    }

    /// Test initializer with an explicit performer and availability flag so the
    /// gate logic can be exercised without firing real trackpad feedback.
    init(performer: HapticPerformer, available: Bool) {
        self.performer = performer
        self.isAvailable = available
    }

    /// Render a haptic cue. Guarded by all four gates; a no-op when any gate
    /// is closed. Never throws and never blocks the main actor.
    public func play(_ pattern: HapticPattern) {
        guard isAvailable, enabled, !muted, !reduceMotion else { return }
        performer.perform(pattern.systemPattern)
        performedPatterns.append(pattern)
    }

    /// Reset the recorded pattern log (test convenience).
    public func resetLog() {
        performedPatterns.removeAll()
    }
}

/// A trackpad haptic performer. The real implementation wraps
/// `NSHapticFeedbackManager`; the mock records calls for tests.
protocol HapticPerformer: AnyObject {
    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern)
}

/// Wraps `NSHapticFeedbackManager.defaultPerformer`. The trackpad performer is
/// available on macOS 10.11+; `perform` is a safe no-op when no trackpad is
/// present, so this never crashes on headless hosts.
private final class SystemHapticPerformer: HapticPerformer {
    let isReady: Bool

    init() {
        // NSHapticFeedbackManager has shipped since macOS 10.11. The class is
        // always present on the supported deployment target (macOS 14+); the
        // performer itself no-ops when no force-touch trackpad is attached.
        self.isReady = true
    }

    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}

/// Test double that records performed patterns without touching the trackpad.
final class RecordingHapticPerformer: HapticPerformer {
    private(set) var performed: [NSHapticFeedbackManager.FeedbackPattern] = []

    func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        performed.append(pattern)
    }

    func reset() { performed.removeAll() }
}
