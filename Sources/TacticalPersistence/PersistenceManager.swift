import Foundation
import TacticalCore

/// Local persistence manager. Handles replays, preferences, and match history
/// using the filesystem (App Support directory). Atomic writes, recovery from
/// partial files, and export/import.
public final class PersistenceManager {
    public let appSupportDir: URL
    public let replaysDir: URL
    public let preferencesFile: URL
    public let trainingProgressFile: URL
    public let lessonSaveFile: URL

    public init(appName: String = "Parallax") {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        appSupportDir = support.appendingPathComponent(appName)
        replaysDir = appSupportDir.appendingPathComponent("Replays")
        preferencesFile = appSupportDir.appendingPathComponent("preferences.json")
        trainingProgressFile = appSupportDir.appendingPathComponent("training-progress.json")
        lessonSaveFile = appSupportDir.appendingPathComponent("lesson-save.json")

        try? fm.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: replaysDir, withIntermediateDirectories: true)
    }

    // MARK: - Replays

    /// Save a replay atomically.
    public func saveReplay(_ replay: Replay) throws -> URL {
        let data = try replay.encode()
        let filename = "replay_\(replay.boardId)_\(Int(replay.createdAt.timeIntervalSince1970)).json"
        let url = replaysDir.appendingPathComponent(filename)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Load a replay from a file URL.
    public func loadReplay(from url: URL) throws -> Replay {
        let data = try Data(contentsOf: url)
        return try Replay.decode(data)
    }

    /// List all saved replays, sorted by date descending.
    public func listReplays() -> [URL] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: replaysDir, includingPropertiesForKeys: [.creationDateKey]) else {
            return []
        }
        return files.filter { $0.pathExtension == "json" }.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date.distantPast
            return da > db
        }
    }

    /// Export a replay to a user-chosen location.
    public func exportReplay(_ replay: Replay, to url: URL) throws {
        let data = try replay.encode()
        try data.write(to: url, options: .atomic)
    }

    /// Import a replay from an external file, validating it.
    /// Accepts both v1 (legacy) and v2 (current) replay formats.
    public func importReplay(from url: URL) throws -> Replay {
        let data = try Data(contentsOf: url)
        let replay = try Replay.decode(data)
        // Validate format version — accept v1 and v2.
        guard replay.formatVersion == 1 || replay.formatVersion == Replay.currentFormatVersion else {
            throw ImportError.unsupportedFormat(replay.formatVersion)
        }
        // Save to replays directory.
        _ = try saveReplay(replay)
        return replay
    }

    public enum ImportError: Error {
        case unsupportedFormat(Int)
    }

    // MARK: - Preferences

    public struct Preferences: Codable {
        public var tickRate: Double = 2.0
        public var botEnabled: Bool = true
        public var botDifficulty: String = "master"
        public var botPersonality: String = "balanced"
        /// Segment 12 — optional grandmaster duel persona id. Empty string
        /// means "derive from botPersonality" (the default, backward-compatible
        /// behavior). Decoded with a default so older saved prefs still load.
        public var botPersonaId: String = ""
        public var sfxVolume: Float = 0.7
        public var ambienceVolume: Float = 0.3
        public var muted: Bool = false
        public var reduceMotion: Bool = false
        public var highContrast: Bool = false
        public var colorVisionSafe: Bool = false
        public var oneHandedMode: Bool = false
        public var preferredBoard: String = "triad"
        public var hapticsEnabled: Bool = true

        public init() {}

        /// Custom decoder: every field uses `decodeIfPresent` so a prefs file
        /// written by an older app version (missing newer keys) still loads,
        /// with missing keys falling back to their defaults. This keeps saved
        /// tickRate/volumes/etc. intact across version upgrades.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            tickRate = try c.decodeIfPresent(Double.self, forKey: .tickRate) ?? 2.0
            botEnabled = try c.decodeIfPresent(Bool.self, forKey: .botEnabled) ?? true
            botDifficulty = try c.decodeIfPresent(String.self, forKey: .botDifficulty) ?? "master"
            botPersonality = try c.decodeIfPresent(String.self, forKey: .botPersonality) ?? "balanced"
            botPersonaId = try c.decodeIfPresent(String.self, forKey: .botPersonaId) ?? ""
            sfxVolume = try c.decodeIfPresent(Float.self, forKey: .sfxVolume) ?? 0.7
            ambienceVolume = try c.decodeIfPresent(Float.self, forKey: .ambienceVolume) ?? 0.3
            muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
            reduceMotion = try c.decodeIfPresent(Bool.self, forKey: .reduceMotion) ?? false
            highContrast = try c.decodeIfPresent(Bool.self, forKey: .highContrast) ?? false
            colorVisionSafe = try c.decodeIfPresent(Bool.self, forKey: .colorVisionSafe) ?? false
            oneHandedMode = try c.decodeIfPresent(Bool.self, forKey: .oneHandedMode) ?? false
            preferredBoard = try c.decodeIfPresent(String.self, forKey: .preferredBoard) ?? "triad"
            hapticsEnabled = try c.decodeIfPresent(Bool.self, forKey: .hapticsEnabled) ?? true
        }
    }

    public func loadPreferences() -> Preferences {
        guard let data = try? Data(contentsOf: preferencesFile),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else {
            return Preferences()
        }
        return prefs
    }

    public func savePreferences(_ prefs: Preferences) throws {
        let data = try JSONEncoder().encode(prefs)
        try data.write(to: preferencesFile, options: .atomic)
    }

    // MARK: - Training Progress (Segment 14)

    /// Persisted training progress: which lessons have been completed, with
    /// the best (lowest) move count and the completion timestamp. Survives
    /// app restarts so the Academy can show checkmarks and best scores.
    public struct TrainingProgress: Codable, Sendable, Hashable {
        /// One entry per completed lesson, keyed by lesson id.
        public struct LessonEntry: Codable, Sendable, Hashable {
            public let lessonId: String
            public let bestMoves: Int
            public let completedAt: Date

            public init(lessonId: String, bestMoves: Int, completedAt: Date) {
                self.lessonId = lessonId
                self.bestMoves = bestMoves
                self.completedAt = completedAt
            }
        }

        public var completedLessons: [String: LessonEntry] = [:]

        public init() {}

        /// Custom decoder: `completedLessons` uses `decodeIfPresent` so a
        /// progress file written by an older app version (or an empty file)
        /// still loads with an empty dictionary.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            completedLessons = try c.decodeIfPresent(
                [String: LessonEntry].self, forKey: .completedLessons) ?? [:]
        }

        private enum CodingKeys: String, CodingKey {
            case completedLessons
        }

        /// Record a lesson completion. Keeps the best (lowest) move count.
        public mutating func recordCompletion(lessonId: String, moves: Int, at date: Date = Date()) {
            if let existing = completedLessons[lessonId] {
                let best = min(existing.bestMoves, moves)
                completedLessons[lessonId] = LessonEntry(
                    lessonId: lessonId, bestMoves: best, completedAt: date)
            } else {
                completedLessons[lessonId] = LessonEntry(
                    lessonId: lessonId, bestMoves: moves, completedAt: date)
            }
        }

        /// True if the lesson has been completed at least once.
        public func isCompleted(_ lessonId: String) -> Bool {
            completedLessons[lessonId] != nil
        }

        /// Best (lowest) move count for a lesson, or nil if not completed.
        public func bestMoves(for lessonId: String) -> Int? {
            completedLessons[lessonId]?.bestMoves
        }
    }

    /// Load training progress. Returns an empty progress if the file is
    /// missing or corrupt (graceful degradation — never blocks the Academy).
    public func loadTrainingProgress() -> TrainingProgress {
        guard let data = try? Data(contentsOf: trainingProgressFile) else {
            return TrainingProgress()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let progress = try? decoder.decode(TrainingProgress.self, from: data) else {
            return TrainingProgress()
        }
        return progress
    }

    /// Save training progress atomically.
    public func saveTrainingProgress(_ progress: TrainingProgress) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(progress)
        try data.write(to: trainingProgressFile, options: .atomic)
    }

    // MARK: - In-progress Lesson Save/Resume (Segment 14)

    /// A saved in-progress training lesson. Captures the engine snapshot,
    /// live counterable-action window, lesson id, move count, and completion
    /// flag so a lesson can be resumed after app restart or navigation away.
    /// The snapshot + counterable actions are the same fields used by the v2
    /// replay format, so reconstruction uses the same Engine initializer
    /// (`Engine.init(restoring:board:counterableActions:)`).
    public struct LessonSaveState: Codable, Sendable, Hashable {
        public let lessonId: String
        public let boardId: String
        public let snapshot: Snapshot
        public let counterableActions: [GameState.CounterableAction]?
        public let moveCount: Int
        public let trainingComplete: Bool
        public let savedAt: Date

        public init(lessonId: String, boardId: String, snapshot: Snapshot,
                    counterableActions: [GameState.CounterableAction]?,
                    moveCount: Int, trainingComplete: Bool,
                    savedAt: Date = Date()) {
            self.lessonId = lessonId
            self.boardId = boardId
            self.snapshot = snapshot
            self.counterableActions = counterableActions
            self.moveCount = moveCount
            self.trainingComplete = trainingComplete
            self.savedAt = savedAt
        }

        /// Reconstruct the engine from the saved state. Uses the same
        /// initializer as v2 replay reconstruction so the counter window is
        /// restored faithfully.
        public func makeEngine(board: BoardDefinition) -> Engine {
            let counterable = counterableActions ?? []
            return Engine(restoring: snapshot, board: board,
                          counterableActions: counterable)
        }
    }

    /// Save the current in-progress lesson state atomically. Overwrites any
    /// previous saved lesson. Called when the player navigates away from a
    /// lesson (stopMatch) or the app is about to terminate.
    public func saveLessonState(_ state: LessonSaveState) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: lessonSaveFile, options: .atomic)
    }

    /// Load a saved in-progress lesson. Returns nil if no save exists or the
    /// file is corrupt (graceful degradation — the Academy just starts fresh).
    public func loadLessonState() -> LessonSaveState? {
        guard let data = try? Data(contentsOf: lessonSaveFile) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(LessonSaveState.self, from: data)
    }

    /// Clear the saved lesson state (e.g. after a lesson is completed or
    /// the player explicitly discards it).
    public func clearLessonState() {
        try? FileManager.default.removeItem(at: lessonSaveFile)
    }
}
