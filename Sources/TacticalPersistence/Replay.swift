import Foundation
import TacticalCore

/// Versioned replay format. A match is fully reproducible from:
/// ruleset version, board definition, initial seed, players, and command stream.
///
/// **Format v1** (legacy): reconstructs from a fresh `Engine(board:matchSeed:)`.
/// Training lessons could not be recorded because their custom initial states
/// (owned nodes, flux, cursors, pre-run setup ticks, live counter windows) were
/// not represented.
///
/// **Format v2** (current): adds optional fields that capture a lesson's
/// authored starting position so every training lesson can be recorded and
/// replayed deterministically:
///   - `lessonId`: the training lesson identifier (nil for regular matches)
///   - `initialSnapshot`: the full game-state snapshot at replay start, so the
///     engine restores the lesson's configured board position instead of the
///     default opening
///   - `initialCounterableActions`: the live counter-window state at replay
///     start, so lessons that pre-ran a setup tick (e.g. the counter lesson)
///     restore their counterable-action record and accept counter commands
///     immediately
///   - `player1PersonaId` / `player2PersonaId`: the Segment 12 duel persona
///     id for each player (nil for v1/v2 replays written before Segment 14).
///     Captured so replay playback can faithfully reconstruct the persona HUD
///     without relying on the current preference. Empty string means "derive
///     from personality" (the default).
///
/// v1 replays decode unchanged (the new fields are optional and absent in v1
/// data). v2 replays written before Segment 14 decode with nil persona ids.
/// `importReplay` accepts both v1 and v2. New replays are always v2.
public struct Replay: Codable, Sendable, Hashable {
    public static let currentFormatVersion = 2

    public var formatVersion: Int
    public var rulesetVersion: String
    public var boardId: String
    public var matchSeed: UInt64
    public var player1Type: PlayerType
    public var player2Type: PlayerType
    public var player1Difficulty: String?
    public var player2Difficulty: String?
    public var player1Personality: String?
    public var player2Personality: String?
    public var ticks: [TickData]
    public var finalSnapshotHash: String
    public var finalEventLogHash: String
    public var createdAt: Date
    public var durationTicks: Int

    // MARK: - v2 additions (optional; absent in v1 replays)

    /// Training lesson identifier. Nil for regular matches; set for training
    /// replays so the replay theater can label and group them.
    public var lessonId: String?

    /// The full game-state snapshot at replay start. When present, replay
    /// reconstruction restores from this snapshot (via
    /// `Engine.init(restoring:board:counterableActions:)`) instead of a fresh
    /// `Engine(board:matchSeed:)`. This captures the lesson's authored starting
    /// position: owned nodes, edge flux, cursors, sealed cycles, etc.
    public var initialSnapshot: Snapshot?

    /// The live counter-window state at replay start. `GameState.init(from:board:)`
    /// resets `lastCounterableActions` to `[]` because the counter window is
    /// transient. This field re-attaches it so a resumed training lesson (e.g.
    /// the counter lesson, which pre-runs a setup tick) can accept counter
    /// commands immediately after restoration.
    public var initialCounterableActions: [GameState.CounterableAction]?

    // MARK: - Segment 14 additions (optional; absent in pre-Segment-14 replays)

    /// Segment 12 duel persona id for player 1. Nil for replays written before
    /// Segment 14. Empty string means "derive from personality" (the default).
    /// Captured so replay playback can reconstruct the persona HUD faithfully.
    public var player1PersonaId: String?

    /// Segment 12 duel persona id for player 2. Nil for replays written before
    /// Segment 14. Empty string means "derive from personality" (the default).
    /// Captured so replay playback can reconstruct the persona HUD faithfully.
    public var player2PersonaId: String?

    public enum PlayerType: String, Codable, Sendable, Hashable {
        case human, bot, network
    }

    public struct TickData: Codable, Sendable, Hashable {
        public var tick: Int
        public var p1Command: CommandData
        public var p2Command: CommandData
        public var snapshotHash: String
    }

    public struct CommandData: Codable, Sendable, Hashable {
        public var action: String
        public var targetNodeId: String?
        public var targetEdgeId: String?
        public var candidateCycleId: String?
        public var counteredSeq: Int?

        public init(from cmd: Command) {
            self.action = cmd.action.rawValue
            self.targetNodeId = cmd.targetNodeId
            self.targetEdgeId = cmd.targetEdgeId
            self.candidateCycleId = cmd.candidateCycleId
            self.counteredSeq = cmd.counteredSeq
        }
        public func toCommand(player: Player) -> Command {
            return Command(
                player: player,
                action: ActionKind(rawValue: action) ?? .yield,
                targetNodeId: targetNodeId,
                targetEdgeId: targetEdgeId,
                candidateCycleId: candidateCycleId,
                counteredSeq: counteredSeq,
                targetTick: 0
            )
        }
    }

    // MARK: - Initializers

    /// v1-compatible initializer for a regular match (fresh engine start).
    /// Produces a v2 replay with nil lesson fields.
    public init(board: BoardDefinition, matchSeed: UInt64,
                p1Type: PlayerType, p2Type: PlayerType) {
        self.formatVersion = Replay.currentFormatVersion
        self.rulesetVersion = String(Balance.version)
        self.boardId = board.id
        self.matchSeed = matchSeed
        self.player1Type = p1Type
        self.player2Type = p2Type
        self.ticks = []
        self.finalSnapshotHash = ""
        self.finalEventLogHash = ""
        self.createdAt = Date()
        self.durationTicks = 0
        self.lessonId = nil
        self.initialSnapshot = nil
        self.initialCounterableActions = nil
        self.player1PersonaId = nil
        self.player2PersonaId = nil
    }

    /// v2 initializer for a training lesson replay. Captures the lesson's
    /// authored starting position (snapshot) and live counter window so the
    /// replay can be reconstructed deterministically. The snapshot is taken
    /// from the lesson's `makeEngine()` result before any trainee commands.
    /// Training lessons have no bot, so persona ids are nil.
    public init(lesson: TrainingLesson, engine: Engine,
                p1Type: PlayerType = .human, p2Type: PlayerType = .human) {
        self.formatVersion = Replay.currentFormatVersion
        self.rulesetVersion = String(Balance.version)
        self.boardId = lesson.board.id
        // The matchSeed in the snapshot is the lesson's seed (default 1).
        self.matchSeed = engine.state.matchSeed
        self.player1Type = p1Type
        self.player2Type = p2Type
        self.ticks = []
        self.finalSnapshotHash = ""
        self.finalEventLogHash = ""
        self.createdAt = Date()
        self.durationTicks = 0
        self.lessonId = lesson.id
        self.initialSnapshot = engine.state.snapshot()
        self.initialCounterableActions = engine.state.lastCounterableActions.isEmpty
            ? nil : engine.state.lastCounterableActions
        self.player1PersonaId = nil
        self.player2PersonaId = nil
    }

    public mutating func recordTick(_ tick: Int, p1Cmd: Command, p2Cmd: Command, snapshotHash: String) {
        ticks.append(TickData(
            tick: tick,
            p1Command: CommandData(from: p1Cmd),
            p2Command: CommandData(from: p2Cmd),
            snapshotHash: snapshotHash
        ))
        durationTicks = tick
    }

    public mutating func finalize(snapshotHash: String, eventLogHash: String) {
        self.finalSnapshotHash = snapshotHash
        self.finalEventLogHash = eventLogHash
    }

    // MARK: - Encoding / Decoding

    /// Encode to JSON data.
    public func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Decode from JSON data. Accepts both v1 and v2 replays; v1 fields
    /// absent in the JSON are decoded as nil for the optional v2 additions.
    public static func decode(_ data: Data) throws -> Replay {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Replay.self, from: data)
    }

    // MARK: - Custom Codable (backward-compatible v1 → v2)

    private enum CodingKeys: String, CodingKey {
        case formatVersion, rulesetVersion, boardId, matchSeed
        case player1Type, player2Type
        case player1Difficulty, player2Difficulty
        case player1Personality, player2Personality
        case ticks, finalSnapshotHash, finalEventLogHash
        case createdAt, durationTicks
        // v2 additions
        case lessonId, initialSnapshot, initialCounterableActions
        // Segment 14 additions
        case player1PersonaId, player2PersonaId
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        rulesetVersion = try c.decode(String.self, forKey: .rulesetVersion)
        boardId = try c.decode(String.self, forKey: .boardId)
        matchSeed = try c.decode(UInt64.self, forKey: .matchSeed)
        player1Type = try c.decode(PlayerType.self, forKey: .player1Type)
        player2Type = try c.decode(PlayerType.self, forKey: .player2Type)
        player1Difficulty = try c.decodeIfPresent(String.self, forKey: .player1Difficulty)
        player2Difficulty = try c.decodeIfPresent(String.self, forKey: .player2Difficulty)
        player1Personality = try c.decodeIfPresent(String.self, forKey: .player1Personality)
        player2Personality = try c.decodeIfPresent(String.self, forKey: .player2Personality)
        ticks = try c.decode([TickData].self, forKey: .ticks)
        finalSnapshotHash = try c.decode(String.self, forKey: .finalSnapshotHash)
        finalEventLogHash = try c.decode(String.self, forKey: .finalEventLogHash)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        durationTicks = try c.decode(Int.self, forKey: .durationTicks)
        // v2 optional fields — absent in v1 replays, decode as nil.
        lessonId = try c.decodeIfPresent(String.self, forKey: .lessonId)
        initialSnapshot = try c.decodeIfPresent(Snapshot.self, forKey: .initialSnapshot)
        initialCounterableActions = try c.decodeIfPresent(
            [GameState.CounterableAction].self, forKey: .initialCounterableActions)
        // Segment 14 optional fields — absent in pre-Segment-14 replays.
        player1PersonaId = try c.decodeIfPresent(String.self, forKey: .player1PersonaId)
        player2PersonaId = try c.decodeIfPresent(String.self, forKey: .player2PersonaId)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(rulesetVersion, forKey: .rulesetVersion)
        try c.encode(boardId, forKey: .boardId)
        try c.encode(matchSeed, forKey: .matchSeed)
        try c.encode(player1Type, forKey: .player1Type)
        try c.encode(player2Type, forKey: .player2Type)
        try c.encodeIfPresent(player1Difficulty, forKey: .player1Difficulty)
        try c.encodeIfPresent(player2Difficulty, forKey: .player2Difficulty)
        try c.encodeIfPresent(player1Personality, forKey: .player1Personality)
        try c.encodeIfPresent(player2Personality, forKey: .player2Personality)
        try c.encode(ticks, forKey: .ticks)
        try c.encode(finalSnapshotHash, forKey: .finalSnapshotHash)
        try c.encode(finalEventLogHash, forKey: .finalEventLogHash)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(durationTicks, forKey: .durationTicks)
        try c.encodeIfPresent(lessonId, forKey: .lessonId)
        try c.encodeIfPresent(initialSnapshot, forKey: .initialSnapshot)
        try c.encodeIfPresent(initialCounterableActions, forKey: .initialCounterableActions)
        try c.encodeIfPresent(player1PersonaId, forKey: .player1PersonaId)
        try c.encodeIfPresent(player2PersonaId, forKey: .player2PersonaId)
    }

    // MARK: - Verification & replay

    /// Verify replay integrity by replaying commands and checking hashes.
    /// For v2 training replays, reconstructs from the captured initial
    /// snapshot + counterable actions. For v1 replays (or v2 regular matches
    /// with no initial snapshot), reconstructs from a fresh engine.
    public func verify(board: BoardDefinition) -> Bool {
        guard board.id == boardId else { return false }
        var engine = makeReplayEngine(board: board)
        for td in ticks {
            let p1Cmd = td.p1Command.toCommand(player: .player1)
            let p2Cmd = td.p2Command.toCommand(player: .player2)
            let (snap, _) = engine.submitTick([p1Cmd, p2Cmd])
            let hash = CanonicalEncoding.snapshotHash(snap)
            if hash != td.snapshotHash { return false }
        }
        let finalSnap = engine.state.snapshot()
        return CanonicalEncoding.snapshotHash(finalSnap) == finalSnapshotHash
    }

    /// Build the engine used for replay reconstruction. If an initial snapshot
    /// is present (v2 training replay), restores from it (with counterable
    /// actions if provided). Otherwise starts from a fresh engine.
    public func makeReplayEngine(board: BoardDefinition) -> Engine {
        if let snap = initialSnapshot {
            let counterable = initialCounterableActions ?? []
            return Engine(restoring: snap, board: board,
                          counterableActions: counterable)
        }
        return Engine(board: board, matchSeed: matchSeed)
    }

    /// Get the command stream for replay.
    public func commandStream() -> [[Command]] {
        ticks.map { td in
            [td.p1Command.toCommand(player: .player1),
             td.p2Command.toCommand(player: .player2)]
        }
    }

    /// True if this replay captures a training lesson (v2 with lessonId).
    public var isTrainingReplay: Bool {
        lessonId != nil && initialSnapshot != nil
    }
}
