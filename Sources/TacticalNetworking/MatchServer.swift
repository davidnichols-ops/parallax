import Foundation
import TacticalCore

/// Local authoritative match service. The server runs the deterministic
/// `Engine`, validates every command before it is applied, and broadcasts
/// snapshots/events. Clients never compute game state — they send commands
/// and receive snapshots.
///
/// This is a **local, in-memory** authority: state lives in process memory
/// behind an `NSLock` and is lost when the process exits. The `ServerStorage`
/// protocol is a seam for a future durable backing store, but the only
/// implementation shipped here is `InMemoryStorage`. There is no hosted
/// authentication, no PostgreSQL/Redis adapter, no anti-cheat heuristic
/// beyond server-side rules re-validation, and no network transport in this
/// type — `LANServer`/`LANClient` in `LANPlay.swift` provide the wire layer.
/// Do not treat this as a production online backend.
public final class MatchServer: @unchecked Sendable {
    public let storage: ServerStorage
    public let config: ServerConfig

    private var pendingQueue: [PendingPlayer] = []
    private var activeMatches: [String: ServerMatch] = [:]
    private var playerSessions: [String: PlayerSession] = [:]
    /// Reconnect tokens. Keyed by sessionId; each binds a playerId to an
    /// assigned `Player` side within one match. Durable for the match lifetime
    /// (in-memory only); a reconnecting client presents its sessionId to
    /// resume without re-matchmaking.
    private var matchSessions: [String: MatchSession] = [:]
    private var lock = NSLock()

    public struct ServerConfig: Sendable {
        public var maxMatches: Int = 1000
        public var matchTimeoutTicks: Int = 600
        public var matchmakingTimeoutSeconds: Double = 30.0
        public var allowedBoards: [String] = ["triad", "grandmaster"]
        public var minRatingDiff: Int = 200

        public init() {}
    }

    public struct PendingPlayer: Sendable {
        public let playerId: String
        public let name: String
        public let rating: Int
        public let preferredBoard: String
        public let queuedAt: Date
    }

    public struct PlayerSession: Sendable {
        public let playerId: String
        public let name: String
        public var rating: Int
        public var currentMatchId: String?
        public var wins: Int
        public var losses: Int
        public var draws: Int
    }

    /// A durable (match-lifetime) binding between a player and their assigned
    /// side in a match. The `sessionId` is the reconnect token.
    public struct MatchSession: Sendable {
        public let sessionId: String
        public let playerId: String
        public let matchId: String
        public let assignedSide: Player
        public var connected: Bool
    }

    public struct ServerMatch: Sendable {
        public let id: String
        public let board: BoardDefinition
        public var engine: Engine
        public let player1Id: String
        public let player2Id: String
        public let matchSeed: UInt64
        /// Per-player queued command for the current tick. Keyed by playerId.
        public var queuedCommands: [String: Command] = [:]
        public var startedAt: Date
        public var status: MatchStatus = .running
        /// Append-only per-tick event frames (one entry per resolved tick).
        /// Used for spectator catch-up and replay framing.
        public var tickFrames: [TickFrame] = []

        public enum MatchStatus: String, Sendable {
            case running, ended, aborted
        }
    }

    /// A deterministic per-tick frame: the commands that resolved, the
    /// end-of-tick snapshot, its canonical hash, and the events emitted.
    /// This is the spectator/replay primitive — a spectator can replay the
    /// frame stream to reconstruct the match, and a reconnecting client can
    /// request frames since its last seen tick.
    public struct TickFrame: Sendable, Codable {
        public let tick: Int
        public let p1Command: Command
        public let p2Command: Command
        public let snapshot: Snapshot
        public let snapshotHash: String
        public let events: [Event]
    }

    public init(storage: ServerStorage = InMemoryStorage(), config: ServerConfig = ServerConfig()) {
        self.storage = storage
        self.config = config
    }

    // MARK: - Session management

    public func registerPlayer(id: String, name: String) -> PlayerSession {
        lock.lock()
        defer { lock.unlock() }
        let rating = storage.getPlayerRating(id) ?? 1000
        let session = PlayerSession(
            playerId: id, name: name, rating: rating,
            currentMatchId: nil, wins: 0, losses: 0, draws: 0
        )
        playerSessions[id] = session
        return session
    }

    // MARK: - Matchmaking

    public func enqueueMatchmaking(playerId: String, preferredBoard: String = "triad") -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let session = playerSessions[playerId],
              session.currentMatchId == nil else { return false }
        guard config.allowedBoards.contains(preferredBoard) else { return false }

        let pending = PendingPlayer(
            playerId: playerId, name: session.name,
            rating: session.rating, preferredBoard: preferredBoard,
            queuedAt: Date()
        )
        pendingQueue.append(pending)
        tryMatchmakeLocked()
        return true
    }

    public func cancelMatchmaking(playerId: String) {
        lock.lock()
        defer { lock.unlock() }
        pendingQueue.removeAll { $0.playerId == playerId }
    }

    /// Internal matchmaking pass. **Must be called with `lock` already held**
    /// (it is invoked from `enqueueMatchmaking` and calls the locked-internal
    /// match creator, never the public re-entrant one).
    private func tryMatchmakeLocked() {
        guard pendingQueue.count >= 2 else { return }

        // Simple matchmaking: pair players with closest rating. The rating
        // gate is relaxed (always matches) so local play never stalls waiting
        // for a perfect opponent; a hosted service would enforce the gate.
        pendingQueue.sort { $0.rating < $1.rating }
        let i = 0
        var idx = i
        while idx + 1 < pendingQueue.count {
            let p1 = pendingQueue[idx]
            let p2 = pendingQueue[idx + 1]
            let board = p1.preferredBoard == "grandmaster"
                ? BoardFactory.grandmaster()
                : BoardFactory.triad()
            // Random seed for matchmaking (non-deterministic across runs).
            // Use createMatch(...) for a deterministic seed in tests.
            let seed = UInt64.random(in: 1...UInt64.max)
            createMatchLocked(player1Id: p1.playerId, player2Id: p2.playerId,
                              board: board, seed: seed)
            pendingQueue.remove(at: idx)
            pendingQueue.remove(at: idx)
        }
    }

    /// Create a match directly between two registered players with an
    /// explicit board and seed. Used by tests that need deterministic seeds.
    /// Returns the match id, or nil if either player is already in a match or
    /// unregistered.
    @discardableResult
    public func createMatch(player1Id: String, player2Id: String,
                            board: BoardDefinition, seed: UInt64) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return createMatchLocked(player1Id: player1Id, player2Id: player2Id,
                                 board: board, seed: seed)
    }

    /// Internal match creator. **Must be called with `lock` already held.**
    @discardableResult
    private func createMatchLocked(player1Id: String, player2Id: String,
                                   board: BoardDefinition, seed: UInt64) -> String? {
        guard let s1 = playerSessions[player1Id], s1.currentMatchId == nil else { return nil }
        guard let s2 = playerSessions[player2Id], s2.currentMatchId == nil else { return nil }
        guard activeMatches.count < config.maxMatches else { return nil }

        let matchId = "match_\(UUID().uuidString.prefix(8))"
        let match = ServerMatch(
            id: matchId, board: board,
            engine: Engine(board: board, matchSeed: seed),
            player1Id: player1Id, player2Id: player2Id,
            matchSeed: seed, startedAt: Date()
        )
        activeMatches[matchId] = match

        // Bind each player to their assigned side with a reconnect token.
        let s1Token = "sess_\(UUID().uuidString)"
        let s2Token = "sess_\(UUID().uuidString)"
        matchSessions[s1Token] = MatchSession(
            sessionId: s1Token, playerId: player1Id,
            matchId: matchId, assignedSide: .player1, connected: true)
        matchSessions[s2Token] = MatchSession(
            sessionId: s2Token, playerId: player2Id,
            matchId: matchId, assignedSide: .player2, connected: true)

        playerSessions[player1Id]?.currentMatchId = matchId
        playerSessions[player2Id]?.currentMatchId = matchId
        return matchId
    }

    /// Look up the reconnect session for a player in a given match.
    public func session(forPlayer playerId: String, inMatch matchId: String) -> MatchSession? {
        lock.lock()
        defer { lock.unlock() }
        return matchSessions.values.first {
            $0.playerId == playerId && $0.matchId == matchId
        }
    }

    // MARK: - Match lifecycle

    /// Submit a command for the current tick. The server is authoritative:
    /// it validates the submitter's identity, the command's claimed player
    /// side, the target tick, duplication, and rules legality before queueing.
    public func submitCommand(playerId: String, command: Command) -> SubmitResult {
        lock.lock()
        defer { lock.unlock() }
        guard let session = playerSessions[playerId],
              let matchId = session.currentMatchId,
              var match = activeMatches[matchId] else {
            return .error("No active match")
        }

        guard match.status == .running else {
            return .error("Match not running")
        }

        // Validate the submitter is bound to this match.
        guard let binding = matchSessions.values.first(where: {
            $0.playerId == playerId && $0.matchId == matchId
        }) else {
            return .error("Player not bound to match")
        }

        // Server-authoritative side check: the command's `player` must match
        // the side the server assigned this submitter. A client cannot act as
        // the other player.
        guard command.player == binding.assignedSide else {
            return .rejected(reason: "command.player (\(command.player.label)) does not match assigned side (\(binding.assignedSide.label))")
        }

        // Validate command player is one of the two valid sides.
        guard command.player == .player1 || command.player == .player2 else {
            return .rejected(reason: "Invalid player in command")
        }

        // Target-tick validation. The engine treats 0 as "current tick"; the
        // authority rejects stale commands (targeting a past tick) and
        // commands too far in the future.
        let currentTick = match.engine.state.tick
        let target = command.targetTick == 0 ? currentTick : command.targetTick
        if target < currentTick {
            return .rejected(reason: "stale command (target tick \(target) < current \(currentTick))")
        }
        if target > currentTick + 1 {
            return .rejected(reason: "future command (target tick \(target) > current+1 (\(currentTick + 1)))")
        }

        // Duplicate-submission guard: one command per player per tick.
        if match.queuedCommands[playerId] != nil {
            return .rejected(reason: "player already submitted a command this tick")
        }

        // Rules legality re-check (the authority never trusts the client).
        let proj = Legality.project(command, state: match.engine.state)
        guard proj.legal else {
            return .rejected(reason: "\(proj.reason ?? .illegalAction)")
        }

        match.queuedCommands[playerId] = command
        activeMatches[matchId] = match

        // If both players have submitted, advance tick.
        if match.queuedCommands.count >= 2 {
            return advanceTick(matchId: matchId)
        }

        return .accepted
    }

    private func advanceTick(matchId: String) -> SubmitResult {
        guard var match = activeMatches[matchId] else { return .error("Match not found") }
        let p1Cmd = match.queuedCommands[match.player1Id] ?? .yield_(.player1)
        let p2Cmd = match.queuedCommands[match.player2Id] ?? .yield_(.player2)
        match.queuedCommands = [:]

        let (snap, events) = match.engine.submitTick([p1Cmd, p2Cmd])
        let frame = TickFrame(
            tick: snap.tick,
            p1Command: p1Cmd, p2Command: p2Cmd,
            snapshot: snap,
            snapshotHash: CanonicalEncoding.snapshotHash(snap),
            events: events)
        match.tickFrames.append(frame)
        activeMatches[matchId] = match

        if match.engine.state.gameStatus == .ended {
            endMatch(matchId: matchId, snapshot: snap)
            return .matchEnded(snapshot: snap, events: events)
        }

        return .tickAdvanced(snapshot: snap, events: events)
    }

    private func endMatch(matchId: String, snapshot: Snapshot) {
        guard let match = activeMatches[matchId] else { return }
        var m = match
        m.status = .ended
        activeMatches[matchId] = m

        // Update ratings.
        if let winner = snapshot.winner {
            let winnerId = winner == .player1 ? match.player1Id : match.player2Id
            let loserId = winner == .player1 ? match.player2Id : match.player1Id
            updateRating(winnerId: winnerId, loserId: loserId, isDraw: false)
        } else {
            updateRating(winnerId: match.player1Id, loserId: match.player2Id, isDraw: true)
        }

        // Clear sessions.
        playerSessions[match.player1Id]?.currentMatchId = nil
        playerSessions[match.player2Id]?.currentMatchId = nil

        // Save match result with the real player ids (not a placeholder).
        storage.saveMatchResult(matchId, player1Id: match.player1Id,
                                player2Id: match.player2Id, snapshot: snapshot)
    }

    private func updateRating(winnerId: String, loserId: String, isDraw: Bool) {
        let winnerRating = playerSessions[winnerId]?.rating ?? 1000
        let loserRating = playerSessions[loserId]?.rating ?? 1000
        let (newWinner, newLoser) = ELOCalculator.update(
            winner: winnerRating, loser: loserRating, isDraw: isDraw
        )
        playerSessions[winnerId]?.rating = newWinner
        playerSessions[loserId]?.rating = newLoser
        if isDraw {
            playerSessions[winnerId]?.draws += 1
            playerSessions[loserId]?.draws += 1
        } else {
            playerSessions[winnerId]?.wins += 1
            playerSessions[loserId]?.losses += 1
        }
        storage.savePlayerRating(winnerId, rating: newWinner)
        storage.savePlayerRating(loserId, rating: newLoser)
    }

    // MARK: - Reconnect + queries

    /// Reconnect a client using its session token. Returns the current full
    /// snapshot, the assigned side, and the match id so the client can resume
    /// rendering from authoritative state. Marks the session connected.
    public func reconnect(sessionId: String) -> ReconnectResult {
        lock.lock()
        defer { lock.unlock() }
        guard var binding = matchSessions[sessionId] else {
            return .invalidToken
        }
        guard let match = activeMatches[binding.matchId] else {
            return .matchGone
        }
        binding.connected = true
        matchSessions[sessionId] = binding
        return .resumed(ReconnectInfo(
            matchId: match.id,
            assignedSide: binding.assignedSide,
            tick: match.engine.state.tick,
            snapshot: match.engine.state.snapshot(),
            matchStatus: match.status
        ))
    }

    /// Mark a session disconnected (e.g. client dropped). The match continues;
    /// the player can reconnect with the same token.
    public func disconnect(sessionId: String) {
        lock.lock()
        defer { lock.unlock() }
        if var binding = matchSessions[sessionId] {
            binding.connected = false
            matchSessions[sessionId] = binding
        }
    }

    /// Full authoritative snapshot for a match (reconnect/spectator catch-up).
    public func getMatchState(matchId: String) -> Snapshot? {
        lock.lock()
        defer { lock.unlock() }
        return activeMatches[matchId]?.engine.state.snapshot()
    }

    /// Per-tick frames for a match (spectator/replay framing). Optionally
    /// limited to frames at or after `sinceTick` so a reconnecting spectator
    /// can fetch only what it missed.
    public func getMatchFrames(matchId: String, sinceTick: Int = 0) -> [TickFrame] {
        lock.lock()
        defer { lock.unlock() }
        guard let match = activeMatches[matchId] else { return [] }
        return match.tickFrames.filter { $0.tick >= sinceTick }
    }

    public func getPlayerSession(_ id: String) -> PlayerSession? {
        lock.lock()
        defer { lock.unlock() }
        return playerSessions[id]
    }

    public func getLeaderboard(limit: Int = 20) -> [PlayerSession] {
        lock.lock()
        defer { lock.unlock() }
        return Array(playerSessions.values)
            .sorted { $0.rating > $1.rating }
            .prefix(limit)
            .map { $0 }
    }

    public var activeMatchCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeMatches.count
    }

    public var pendingQueueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return pendingQueue.count
    }
}

public enum SubmitResult: Sendable {
    case accepted
    case rejected(reason: String)
    case tickAdvanced(snapshot: Snapshot, events: [Event])
    case matchEnded(snapshot: Snapshot, events: [Event])
    case error(String)
}

/// Reconnect outcome.
public enum ReconnectResult: Sendable {
    case resumed(ReconnectInfo)
    case invalidToken
    case matchGone
}

public struct ReconnectInfo: Sendable {
    public let matchId: String
    public let assignedSide: Player
    public let tick: Int
    public let snapshot: Snapshot
    public let matchStatus: MatchServer.ServerMatch.MatchStatus
}

// MARK: - Storage protocol

/// Seam for a future durable backing store. The only implementation shipped
/// here is `InMemoryStorage` (process-local, non-persistent). A hosted
/// backend would supply a PostgreSQL/Redis adapter; none is included.
public protocol ServerStorage: Sendable {
    func getPlayerRating(_ id: String) -> Int?
    func savePlayerRating(_ id: String, rating: Int)
    /// Persist a completed match result with the real player ids so per-player
    /// history is accurate. (The previous signature dropped the player ids and
    /// hardcoded a placeholder, corrupting history.)
    func saveMatchResult(_ matchId: String, player1Id: String, player2Id: String,
                         snapshot: Snapshot)
    func getMatchResult(_ matchId: String) -> Snapshot?
    func getPlayerHistory(_ id: String, limit: Int) -> [String]
}

/// In-memory storage (for testing and single-instance local servers).
/// Not persistent across process restarts.
public final class InMemoryStorage: ServerStorage, @unchecked Sendable {
    private var ratings: [String: Int] = [:]
    private var matchResults: [String: Snapshot] = [:]
    private var playerHistory: [String: [String]] = [:]
    private var lock = NSLock()

    public init() {}

    public func getPlayerRating(_ id: String) -> Int? {
        lock.lock(); defer { lock.unlock() }
        return ratings[id]
    }

    public func savePlayerRating(_ id: String, rating: Int) {
        lock.lock(); defer { lock.unlock() }
        ratings[id] = rating
    }

    public func saveMatchResult(_ matchId: String, player1Id: String, player2Id: String,
                                snapshot: Snapshot) {
        lock.lock(); defer { lock.unlock() }
        matchResults[matchId] = snapshot
        playerHistory[player1Id, default: []].append(matchId)
        playerHistory[player2Id, default: []].append(matchId)
    }

    public func getMatchResult(_ matchId: String) -> Snapshot? {
        lock.lock(); defer { lock.unlock() }
        return matchResults[matchId]
    }

    public func getPlayerHistory(_ id: String, limit: Int) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(playerHistory[id, default: []].suffix(limit))
    }
}

// MARK: - ELO Rating

public enum ELOCalculator {
    public static let kFactor = 32

    public static func update(winner: Int, loser: Int, isDraw: Bool) -> (Int, Int) {
        let expectedWinner = 1.0 / (1.0 + pow(10.0, Double(loser - winner) / 400.0))
        let expectedLoser = 1.0 - expectedWinner

        if isDraw {
            let delta = Double(kFactor) * (0.5 - expectedWinner)
            return (Int(Double(winner) + delta), Int(Double(loser) - delta))
        } else {
            let delta = Double(kFactor) * (1.0 - expectedWinner)
            return (Int(Double(winner) + delta), Int(Double(loser) - delta))
        }
    }
}
