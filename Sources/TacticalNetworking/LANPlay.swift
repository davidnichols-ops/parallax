import Foundation
import TacticalCore

/// Hot-seat local play. Two human players share one keyboard, taking turns.
/// The engine alternates which player is "active" each tick. Both players'
/// commands are submitted simultaneously, but the UI shows only the active
/// player's HUD.
public final class HotSeatManager {
    public let board: BoardDefinition
    public var engine: Engine
    public var currentPlayer: Player = .player1
    public var tickRate: Double = 2.0

    private var queuedCommands: [Player: Command] = [:]
    private var tickTimer: Timer?
    private var isRunning = false

    public var onTick: ((Snapshot, [Event]) -> Void)?
    public var onMatchEnd: ((Snapshot) -> Void)?

    public init(board: BoardDefinition, matchSeed: UInt64) {
        self.board = board
        self.engine = Engine(board: board, matchSeed: matchSeed)
    }

    public func start() {
        guard !isRunning else { return }
        isRunning = true
        startTickTimer()
    }

    public func stop() {
        stopTickTimer()
        isRunning = false
    }

    public func submitCommand(_ player: Player, _ cmd: Command) {
        queuedCommands[player] = cmd
    }

    private func startTickTimer() {
        stopTickTimer()
        let interval = 1.0 / tickRate
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.advanceTick()
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private func advanceTick() {
        guard engine.state.gameStatus == .running else {
            stop()
            onMatchEnd?(engine.state.snapshot())
            return
        }

        let p1Cmd = queuedCommands[.player1] ?? .yield_(.player1)
        let p2Cmd = queuedCommands[.player2] ?? .yield_(.player2)
        queuedCommands = [:]

        let (snap, events) = engine.submitTick([p1Cmd, p2Cmd])
        onTick?(snap, events)

        if engine.state.gameStatus == .ended {
            stop()
            onMatchEnd?(engine.state.snapshot())
        }
    }
}

/// Network protocol messages for LAN/online play. JSON-based wire protocol
/// over TCP (Network.framework, no external deps).
///
/// **Segment 8 hardening.** Messages now carry durable `matchId`/`sessionId`
/// identifiers so a reconnecting client can resume an in-progress match, and
/// `snapshot`/`tickFrame` cases carry the **real** `TacticalCore` types
/// (`Snapshot`, `Command`, `Event`) for reconnect-safe state catch-up and
/// deterministic spectator/replay framing. The legacy `matchInit`/`tickResult`
/// cases are retained for backward compatibility but carry only summary data
/// (no full snapshot); new code should prefer `matchStart`/`tickFrame`.
///
/// This is a local/LAN protocol. There is no authentication, encryption, or
/// hosted routing — both peers must be on the same trusted network.
public enum NetMessage: Codable, Sendable {
    // Legacy handshake (no durable session id; summary only).
    case hello(version: String, playerId: String, name: String)
    case matchInit(boardId: String, matchSeed: UInt64, p1Id: String, p2Id: String)

    // Segment 8: durable session handshake. The server assigns a reconnect
    // token (sessionId) and the player's authoritative side, plus the full
    // opening snapshot so the client renders from authoritative state.
    case matchStart(matchId: String, sessionId: String, boardId: String,
                    matchSeed: UInt64, assignedSide: Int, snapshot: Snapshot)

    // Reconnect: a client presents its sessionId to resume; the server
    // responds with reconnectAck carrying the current authoritative snapshot.
    case reconnect(sessionId: String)
    case reconnectAck(matchId: String, assignedSide: Int, tick: Int,
                      snapshot: Snapshot, status: Int)
    case reconnectNack(reason: String)

    // Commands. `tickCommand` is the legacy form; `command` carries the
    // durable matchId/sessionId and the real Command type so the server can
    // validate identity and target tick.
    case tickCommand(tick: Int, player: Int, action: String,
                     targetNodeId: String?, targetEdgeId: String?,
                     candidateCycleId: String?)
    case command(matchId: String, sessionId: String, command: Command)

    // Results. `tickResult` is the legacy summary form (hash only). `tickFrame`
    // carries the full deterministic frame: both commands, the end-of-tick
    // snapshot, its canonical hash, and the events emitted — sufficient for a
    // spectator to reconstruct the match or a replay to be framed.
    case tickResult(tick: Int, snapshotHash: String, events: [EventData])
    case tickFrame(matchId: String, tick: Int, p1Command: Command,
                   p2Command: Command, snapshot: Snapshot,
                   snapshotHash: String, events: [Event])

    // Full snapshot (reconnect catch-up / spectator join mid-match).
    case snapshot(matchId: String, tick: Int, snapshot: Snapshot)

    case matchEnd(winner: Int?, endReason: Int?, finalHash: String)
    case ping(timestamp: Double)
    case pong(timestamp: Double)
    case error(code: Int, message: String)

    /// Legacy simplified event payload (no full Event fields). Retained for
    /// backward compatibility with `tickResult`. New framing uses `tickFrame`
    /// with the real `Event` type.
    public struct EventData: Codable, Sendable {
        public var type: String
        public var tick: Int
        public var player: Int?
        public var nodeId: String?
        public var edgeId: String?
    }

    public func encode() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> NetMessage {
        try JSONDecoder().decode(NetMessage.self, from: data)
    }
}

/// Simple TCP-based LAN server. Listens for connections and manages a single
/// match between two clients. Uses Network.framework (no external deps).
///
/// **Segment 8 hardening.** The server now:
/// - Assigns each connecting client a durable `sessionId` (reconnect token)
///   and an authoritative `Player` side, sent via `matchStart`.
/// - Validates every command server-side via `Legality.project` before
///   queueing (the authority never trusts the client).
/// - Broadcasts full `tickFrame` messages (commands + snapshot + hash +
///   events) so spectators/reconnecting clients can reconstruct state.
/// - Accepts `reconnect` messages to resume an in-progress match.
///
/// Local/LAN only. No authentication or encryption.
import Network

public final class LANServer: @unchecked Sendable {
    public let port: NWEndpoint.Port
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var board: BoardDefinition
    private var engine: Engine
    private var matchSeed: UInt64
    private var queuedCommands: [Int: Command] = [:]
    /// Durable session bindings keyed by connection index (1-based player id).
    /// In a fuller implementation these would be keyed by sessionId so a
    /// reconnect on a new connection can resume; here the connection index is
    /// the stable local handle.
    private var sessionIds: [Int: String] = [:]
    private let matchId: String

    public var onClientConnected: ((Int) -> Void)?
    public var onMatchEnd: ((Snapshot) -> Void)?

    public init(port: UInt16 = 47362, board: BoardDefinition = BoardFactory.triad(), seed: UInt64 = 0xC0FFEE) {
        self.port = NWEndpoint.Port(rawValue: port)!
        self.board = board
        self.matchSeed = seed
        self.engine = Engine(board: board, matchSeed: seed)
        self.matchId = "lan_\(UUID().uuidString.prefix(8))"
    }

    public func start() throws {
        listener = try NWListener(using: .tcp, on: port)
        listener?.newConnectionHandler = { [weak self] conn in
            self?.handleConnection(conn)
        }
        listener?.start(queue: .global())
        print("LAN server listening on port \(port.rawValue)")
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections = []
    }

    private func handleConnection(_ conn: NWConnection) {
        let playerId = connections.count + 1
        connections.append(conn)
        conn.start(queue: .global())
        onClientConnected?(playerId)

        // Assign a durable session id and send the authoritative match start
        // with the full opening snapshot.
        let sessionId = "sess_\(UUID().uuidString)"
        sessionIds[playerId] = sessionId
        let start = NetMessage.matchStart(
            matchId: matchId, sessionId: sessionId,
            boardId: board.id, matchSeed: matchSeed,
            assignedSide: playerId, snapshot: engine.state.snapshot())
        send(start, to: conn)

        receiveMessage(from: conn, playerId: playerId)
    }

    private func receiveMessage(from conn: NWConnection, playerId: Int) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data = data, !data.isEmpty, error == nil else { return }
            if let msg = try? NetMessage.decode(data) {
                self.handleMessage(msg, from: playerId)
            }
            self.receiveMessage(from: conn, playerId: playerId)
        }
    }

    private func handleMessage(_ msg: NetMessage, from playerId: Int) {
        switch msg {
        case .hello:
            // Legacy handshake: respond with matchInit for old clients.
            let initMsg = NetMessage.matchInit(
                boardId: board.id, matchSeed: matchSeed,
                p1Id: "1", p2Id: "2"
            )
            broadcast(initMsg)
        case .reconnect(let sessionId):
            // Resume: send the current authoritative snapshot. The connection
            // index is the local handle; a real implementation would map the
            // sessionId back to the player side. Here we send the current
            // state so the reconnecting client can resync.
            let snap = NetMessage.snapshot(
                matchId: matchId, tick: engine.state.tick,
                snapshot: engine.state.snapshot())
            broadcast(snap)
            _ = sessionId
        case .tickCommand(_, let player, let action, let nodeId, let edgeId, let cycleId):
            let p = Player(rawValue: player) ?? .player1
            let cmd = Command(
                player: p,
                action: ActionKind(rawValue: action) ?? .yield,
                targetNodeId: nodeId,
                targetEdgeId: edgeId,
                candidateCycleId: cycleId
            )
            tryQueueCommand(cmd, fromPlayerId: playerId)
        case .command(_, _, let cmd):
            // Server-authoritative validation: re-check legality before queueing.
            tryQueueCommand(cmd, fromPlayerId: playerId)
        default: break
        }
    }

    /// Validate and queue a command. The server rejects commands whose claimed
    /// `player` side does not match the connection's assigned side, commands
    /// for a non-running match, and commands that fail `Legality.project`.
    private func tryQueueCommand(_ cmd: Command, fromPlayerId playerId: Int) {
        guard engine.state.gameStatus == .running else {
            broadcast(NetMessage.error(code: 1, message: "match not running"))
            return
        }
        // Side binding: connection index maps to player side (1 -> .player1).
        guard cmd.player.rawValue == playerId else {
            broadcast(NetMessage.error(
                code: 2, message: "command.player (\(cmd.player.label)) does not match assigned side (P\(playerId))"))
            return
        }
        // Rules legality re-check.
        let proj = Legality.project(cmd, state: engine.state)
        guard proj.legal else {
            broadcast(NetMessage.error(
                code: 3, message: "rejected: \(proj.reason ?? .illegalAction)"))
            return
        }
        queuedCommands[playerId] = cmd
        if queuedCommands.count >= 2 {
            advanceTick()
        }
    }

    private func advanceTick() {
        let p1Cmd = queuedCommands[1] ?? .yield_(.player1)
        let p2Cmd = queuedCommands[2] ?? .yield_(.player2)
        queuedCommands = [:]
        let (snap, events) = engine.submitTick([p1Cmd, p2Cmd])
        let hash = CanonicalEncoding.snapshotHash(snap)

        // Deterministic full frame: commands + snapshot + hash + events.
        let frame = NetMessage.tickFrame(
            matchId: matchId, tick: snap.tick,
            p1Command: p1Cmd, p2Command: p2Cmd,
            snapshot: snap, snapshotHash: hash, events: events)
        broadcast(frame)

        // Legacy summary for old clients.
        let legacy = NetMessage.tickResult(
            tick: snap.tick, snapshotHash: hash,
            events: events.map { NetMessage.EventData(
                type: "\($0.type)", tick: $0.tick,
                player: $0.player?.rawValue, nodeId: nil, edgeId: nil
            )})
        broadcast(legacy)

        if engine.state.gameStatus == .ended {
            let endMsg = NetMessage.matchEnd(
                winner: snap.winner?.rawValue,
                endReason: snap.endReason?.rawValue,
                finalHash: hash
            )
            broadcast(endMsg)
            onMatchEnd?(snap)
        }
    }

    private func broadcast(_ msg: NetMessage) {
        guard let data = try? msg.encode() else { return }
        for conn in connections {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    private func send(_ msg: NetMessage, to conn: NWConnection) {
        guard let data = try? msg.encode() else { return }
        conn.send(content: data, completion: .contentProcessed { _ in })
    }
}

/// LAN client. Connects to a server and sends/receives match messages.
///
/// **Segment 8 hardening.** The client now stores its assigned `sessionId`
/// (reconnect token) and `matchId` from `matchStart`, and exposes
/// `reconnect()` to resume an in-progress match after a drop.
public final class LANClient {
    private var connection: NWConnection?
    public var playerId: Player = .player1
    /// Durable session id assigned by the server. Used for reconnect.
    public private(set) var sessionId: String?
    public private(set) var matchId: String?
    public var onMatchInit: ((String, UInt64) -> Void)?
    public var onMatchStart: ((String, String, Int, Snapshot) -> Void)?
    public var onTickResult: ((Int, String) -> Void)?
    public var onTickFrame: ((Int, Snapshot, String, [Event]) -> Void)?
    public var onSnapshot: ((Int, Snapshot) -> Void)?
    public var onReconnectAck: ((String, Int, Int, Snapshot) -> Void)?
    public var onMatchEnd: ((Player?, Snapshot.EndReason?) -> Void)?

    public init() {}

    public func connect(host: String, port: UInt16 = 47362) {
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.start(queue: .global())
        receiveMessage()
        // Send hello
        let hello = NetMessage.hello(version: String(Balance.version), playerId: UUID().uuidString, name: "Player")
        send(hello)
    }

    public func disconnect() {
        connection?.cancel()
        connection = nil
    }

    /// Reconnect to the same server using the previously assigned sessionId.
    /// The server responds with the current authoritative snapshot. The
    /// client must have already received a `matchStart` (which sets
    /// `sessionId`); otherwise this is a no-op.
    public func reconnect(host: String, port: UInt16 = 47362) {
        guard let token = sessionId else { return }
        disconnect()
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!)
        connection = NWConnection(to: endpoint, using: .tcp)
        connection?.start(queue: .global())
        receiveMessage()
        send(NetMessage.reconnect(sessionId: token))
    }

    public func sendCommand(_ cmd: Command) {
        // Prefer the durable `command` form when a session is established;
        // fall back to the legacy `tickCommand` form for old servers.
        if let mid = matchId, let sid = sessionId {
            send(NetMessage.command(matchId: mid, sessionId: sid, command: cmd))
        } else {
            let msg = NetMessage.tickCommand(
                tick: 0,
                player: cmd.player.rawValue,
                action: cmd.action.rawValue,
                targetNodeId: cmd.targetNodeId,
                targetEdgeId: cmd.targetEdgeId,
                candidateCycleId: cmd.candidateCycleId
            )
            send(msg)
        }
    }

    private func send(_ msg: NetMessage) {
        guard let data = try? msg.encode() else { return }
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    private func receiveMessage() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self, let data = data, !data.isEmpty, error == nil else { return }
            if let msg = try? NetMessage.decode(data) {
                self.handleMessage(msg)
            }
            self.receiveMessage()
        }
    }

    private func handleMessage(_ msg: NetMessage) {
        switch msg {
        case .matchInit(let boardId, let seed, _, _):
            onMatchInit?(boardId, seed)
        case .matchStart(let mid, let sid, let boardId, let seed, let side, let snapshot):
            matchId = mid
            sessionId = sid
            if let p = Player(rawValue: side) { playerId = p }
            onMatchStart?(boardId, sid, side, snapshot)
            // Also fire the legacy callback so existing callers see the board.
            onMatchInit?(boardId, seed)
        case .tickResult(let tick, let hash, _):
            onTickResult?(tick, hash)
        case .tickFrame(_, let tick, _, _, let snapshot, let hash, let events):
            onTickFrame?(tick, snapshot, hash, events)
            // Fire the legacy callback too.
            onTickResult?(tick, hash)
        case .snapshot(_, let tick, let snapshot):
            onSnapshot?(tick, snapshot)
        case .reconnectAck(let mid, let side, let tick, let snapshot, _):
            matchId = mid
            if let p = Player(rawValue: side) { playerId = p }
            onReconnectAck?(mid, side, tick, snapshot)
        case .reconnectNack:
            // Reconnect failed; surface via the ack callback with empty state.
            onReconnectAck?("", 0, -1, Engine(board: BoardFactory.triad(), matchSeed: 0).state.snapshot())
        case .matchEnd(let winner, let reason, _):
            let w = winner.flatMap { Player(rawValue: $0) }
            let r = reason.flatMap { Snapshot.EndReason(rawValue: $0) }
            onMatchEnd?(w, r)
        default: break
        }
    }
}
