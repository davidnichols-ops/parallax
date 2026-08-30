import Foundation

/// Mutable per-node runtime state.
public struct NodeState: Codable, Sendable, Hashable {
    public var owner: Owner = .neutral
    public var influence: Int = 0          // 0..100
    public var locked: Bool = false
    public var sealedCycleIds: [String] = []   // sorted; cycle memberships
    public var shieldTicks: Int = 0        // remaining shield window
    public init() {}

    // Custom encode to guarantee sorted cycle ids (deterministic encoding).
    private enum CodingKeys: String, CodingKey {
        case owner, influence, locked, sealedCycleIds, shieldTicks
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(Owner.self, forKey: .owner)
        influence = try c.decode(Int.self, forKey: .influence)
        locked = try c.decode(Bool.self, forKey: .locked)
        sealedCycleIds = (try c.decode([String].self, forKey: .sealedCycleIds)).sorted()
        shieldTicks = try c.decode(Int.self, forKey: .shieldTicks)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(owner, forKey: .owner)
        try c.encode(influence, forKey: .influence)
        try c.encode(locked, forKey: .locked)
        try c.encode(sealedCycleIds.sorted(), forKey: .sealedCycleIds)
        try c.encode(shieldTicks, forKey: .shieldTicks)
    }
}

/// Mutable per-edge runtime state.
public struct EdgeState: Codable, Sendable, Hashable {
    public var owner: Owner = .neutral
    public var flux: Int = 0               // 0..100
    public var severed: Bool = false
    public var cooldown: Int = 0
    public var sealed: Bool = false
    public var sealedCycleIds: [String] = []
    public var lastTraversedBy: Owner? = nil
    public var lastTraverseTick: Int = -1
    public init() {}

    private enum CodingKeys: String, CodingKey {
        case owner, flux, severed, cooldown, sealed, sealedCycleIds
        case lastTraversedBy, lastTraverseTick
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        owner = try c.decode(Owner.self, forKey: .owner)
        flux = try c.decode(Int.self, forKey: .flux)
        severed = try c.decode(Bool.self, forKey: .severed)
        cooldown = try c.decode(Int.self, forKey: .cooldown)
        sealed = try c.decode(Bool.self, forKey: .sealed)
        sealedCycleIds = (try c.decode([String].self, forKey: .sealedCycleIds)).sorted()
        lastTraversedBy = try c.decodeIfPresent(Owner.self, forKey: .lastTraversedBy)
        lastTraverseTick = try c.decode(Int.self, forKey: .lastTraverseTick)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(owner, forKey: .owner)
        try c.encode(flux, forKey: .flux)
        try c.encode(severed, forKey: .severed)
        try c.encode(cooldown, forKey: .cooldown)
        try c.encode(sealed, forKey: .sealed)
        try c.encode(sealedCycleIds.sorted(), forKey: .sealedCycleIds)
        try c.encodeIfPresent(lastTraversedBy, forKey: .lastTraversedBy)
        try c.encode(lastTraverseTick, forKey: .lastTraverseTick)
    }
}

/// Mutable per-face runtime state.
public struct FaceState: Codable, Sendable, Hashable {
    public var controller: Owner? = nil    // nil = uncontrolled
    public var sealedBy: Owner? = nil
    public var sealedCycleId: String? = nil
    public init() {}
}

public struct PlayerState: Codable, Sendable, Hashable {
    public var flux: Int = Balance.maxFlux
    public var score: Int = 0
    public var composure: Int = 50
    public var initiative: Int = 0
    public var successfulCounters: Int = 0
    public var sealedCycles: Int = 0
    public var moves: Int = 0              // accepted meaningful actions
    public var cursorPlateau: Int = 0
    public var cursorX: Int = 0
    public var cursorY: Int = 0
    public init() {}
}

/// Pending feint marker (private to the feinting player; only existence is
/// visible to the opponent).
public struct FeintMarker: Codable, Sendable, Hashable {
    public let nodeId: String
    public let expiresAtTick: Int
}

/// A complete, serializable snapshot of the simulation at the end of a tick.
/// Uses flat ordered fields (not enum-keyed dictionaries) so that canonical
/// encoding is deterministic across processes and architectures.
public struct Snapshot: Codable, Sendable, Hashable {
    public let tick: Int
    public let rulesetVersion: Int
    public let boardId: String
    public let boardVersion: Int
    public let matchSeed: UInt64
    public let nodes: [String: NodeState]
    public let edges: [String: EdgeState]
    public let faces: [String: FaceState]
    public let player1State: PlayerState
    public let player2State: PlayerState
    public let feintsP1: [FeintMarker]
    public let feintsP2: [FeintMarker]
    public let firstActorThisTick: Player   // canonical-order initiative flip
    public let gameStatus: GameStatus
    public let winner: Player?
    public let endReason: EndReason?
    public let parity: Int
    public let ticksSinceMeaningfulChange: Int

    public enum GameStatus: Int, Codable, Sendable, Hashable {
        case running = 0
        case paused = 1
        case ended = 2
    }

    public enum EndReason: Int, Codable, Sendable, Hashable {
        case decisiveScore = 0
        case resignation = 1
        case boardExhaustion = 2
        case timeout = 3
        case voided = 4
    }

    /// Convenience accessor mirroring the GameState dict form.
    public var playerStates: [Player: PlayerState] {
        [.player1: player1State, .player2: player2State]
    }
    public var feints: [Player: [FeintMarker]] {
        [.player1: feintsP1, .player2: feintsP2]
    }
}

/// The full mutable game state. Reconstructed from a `Snapshot` for replay.
public struct GameState: Sendable {
    public let board: BoardDefinition
    public let matchSeed: UInt64
    public var tick: Int = 0
    public var nodes: [String: NodeState]
    public var edges: [String: EdgeState]
    public var faces: [String: FaceState]
    public var playerStates: [Player: PlayerState]
    public var feints: [Player: [FeintMarker]] = [.player1: [], .player2: []]
    public var firstActorThisTick: Player = .player1
    public var gameStatus: Snapshot.GameStatus = .running
    public var winner: Player? = nil
    public var endReason: Snapshot.EndReason? = nil
    public var parity: Int = 0
    public var ticksSinceMeaningfulChange: Int = 0
    public var lastCounterableActions: [CounterableAction] = []  // actions from previous tick

    public struct CounterableAction: Codable, Sendable, Hashable {
        public let seq: Int
        public let player: Player
        public let action: ActionKind
        public let targetEdge: String?
        public let targetNode: String?
        public let tick: Int

        public init(seq: Int, player: Player, action: ActionKind,
                    targetEdge: String?, targetNode: String?, tick: Int) {
            self.seq = seq
            self.player = player
            self.action = action
            self.targetEdge = targetEdge
            self.targetNode = targetNode
            self.tick = tick
        }
    }

    public init(board: BoardDefinition, matchSeed: UInt64) {
        self.board = board
        self.matchSeed = matchSeed
        var ns: [String: NodeState] = [:]
        for n in board.nodes { ns[n.id] = NodeState() }
        // anchors
        for a in board.anchors.player1 {
            ns[a]?.owner = .player1; ns[a]?.influence = 100; ns[a]?.locked = true
        }
        for a in board.anchors.player2 {
            ns[a]?.owner = .player2; ns[a]?.influence = 100; ns[a]?.locked = true
        }
        self.nodes = ns
        var es: [String: EdgeState] = [:]
        for e in board.edges { es[e.id] = EdgeState() }
        self.edges = es
        var fs: [String: FaceState] = [:]
        for f in board.faces { fs[f.id] = FaceState() }
        self.faces = fs
        var ps: [Player: PlayerState] = [:]
        ps[.player1] = PlayerState()
        ps[.player2] = PlayerState()
        // P1 cursor at first anchor
        if let a = board.anchors.player1.first, let def = board.nodeMap[a] {
            ps[.player1]?.cursorPlateau = def.plateau
            ps[.player1]?.cursorX = def.x
            ps[.player1]?.cursorY = def.y
        }
        if let a = board.anchors.player2.first, let def = board.nodeMap[a] {
            ps[.player2]?.cursorPlateau = def.plateau
            ps[.player2]?.cursorX = def.x
            ps[.player2]?.cursorY = def.y
        }
        self.playerStates = ps
    }

    public func snapshot() -> Snapshot {
        Snapshot(
            tick: tick, rulesetVersion: board.rulesetVersion,
            boardId: board.id, boardVersion: board.version, matchSeed: matchSeed,
            nodes: nodes, edges: edges, faces: faces,
            player1State: playerStates[.player1] ?? PlayerState(),
            player2State: playerStates[.player2] ?? PlayerState(),
            feintsP1: feints[.player1] ?? [],
            feintsP2: feints[.player2] ?? [],
            firstActorThisTick: firstActorThisTick,
            gameStatus: gameStatus, winner: winner, endReason: endReason,
            parity: parity, ticksSinceMeaningfulChange: ticksSinceMeaningfulChange
        )
    }

    public init(from s: Snapshot, board: BoardDefinition) {
        self.board = board
        self.matchSeed = s.matchSeed
        self.tick = s.tick
        self.nodes = s.nodes
        self.edges = s.edges
        self.faces = s.faces
        self.playerStates = [.player1: s.player1State, .player2: s.player2State]
        self.feints = [.player1: s.feintsP1, .player2: s.feintsP2]
        self.firstActorThisTick = s.firstActorThisTick
        self.gameStatus = s.gameStatus
        self.winner = s.winner
        self.endReason = s.endReason
        self.parity = s.parity
        self.ticksSinceMeaningfulChange = s.ticksSinceMeaningfulChange
        self.lastCounterableActions = []
    }
}
