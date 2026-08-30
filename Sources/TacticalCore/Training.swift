import Foundation

/// The Academy: authored training lessons that teach the engine's real
/// mechanics (pulse, forge, seal, reinforce, traverse, sever, counter,
/// yield/parity). Each lesson is a genuinely solvable scenario with a
/// separate goal predicate and a verified reference solution (see
/// `Tests/TacticalCoreTests/TrainingTests.swift`).
///
/// The public surface is fixed by the shared build brief:
///   - `TrainingCatalog.lessons: [TrainingLesson]`
///   - `TrainingLesson` is `Identifiable + Sendable` with `id`, `title`,
///     `briefing`, `objective`, `hint`, `initialSelection`, `parMoves`,
///     `board`, `makeEngine() -> Engine`, and
///     `isComplete(state: GameState, events: [Event]) -> Bool`.
///
/// `makeEngine()` and `isComplete(state:events:)` are **methods** (not stored
/// closure properties) so callers invoke them with argument labels exactly as
/// the brief specifies. The underlying behavior is held in private
/// `@Sendable` closures (`engineFactory`, `completionPredicate`) so the struct
/// stays a value type with no captured mutable state.
///
/// Lessons never mutate the core engine or rules. They construct focused
/// starting positions by building a `GameState`, configuring its public
/// fields, snapshotting it, and restoring it via
/// `Engine.init(restoring:board:)` — the engine's supported state-restoration
/// entry point. Board IDs are `triad`/`grandmaster` so replay lookup stays
/// valid. Goal predicates are outcome-based (ownership, sealed cycles, shield
/// windows, successful counters, yield events + parity) so an `actionRejected`
/// event can never satisfy completion.

public struct TrainingLesson: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let briefing: String
    public let objective: String
    public let hint: String
    public let initialSelection: String
    public let parMoves: Int
    public let board: BoardDefinition

    private let engineFactory: @Sendable () -> Engine
    private let completionPredicate: @Sendable (GameState, [Event]) -> Bool

    public init(id: String, title: String, briefing: String, objective: String,
                hint: String, initialSelection: String, parMoves: Int,
                board: BoardDefinition,
                makeEngine: @escaping @Sendable () -> Engine,
                isComplete: @escaping @Sendable (GameState, [Event]) -> Bool) {
        self.id = id; self.title = title; self.briefing = briefing
        self.objective = objective; self.hint = hint
        self.initialSelection = initialSelection; self.parMoves = parMoves
        self.board = board
        self.engineFactory = makeEngine
        self.completionPredicate = isComplete
    }

    /// Build a fresh engine whose starting position is the lesson's authored
    /// scenario. For lessons that need an opponent tempo (e.g. the counter
    /// lesson), the factory pre-runs the necessary setup tick(s) so the
    /// returned engine is in a legal, solvable state.
    public func makeEngine() -> Engine { engineFactory() }

    /// Outcome-based completion test. Callable with argument labels per the
    /// shared brief. A rejected action never satisfies this predicate because
    /// every predicate inspects real state (ownership, shield windows, sealed
    /// cycles, successful counters, yield events + parity), not event types.
    public func isComplete(state: GameState, events: [Event]) -> Bool {
        completionPredicate(state, events)
    }
}

public enum TrainingCatalog {
    /// All authored lessons, ordered from fundamental to advanced.
    public static let lessons: [TrainingLesson] = [
        .pulseFirstCapture,
        .forgeClaimLink,
        .sealCloseCycle,
        .reinforceAnchorShield,
        .traverseCrossConduit,
        .severCutEnemyLine,
        .counterParryVector,
        .yieldHoldParity
    ]
}

// MARK: - Setup helpers

/// Build a fresh engine whose starting position is a configured `GameState`.
/// Uses the engine's public restoration initializer so no core rules are
/// bypassed: the authority still re-checks legality on every submitted tick.
private func setupEngine(board: BoardDefinition, seed: UInt64 = 1,
                         configure: @Sendable (inout GameState) -> Void) -> Engine {
    var gs = GameState(board: board, matchSeed: seed)
    configure(&gs)
    // Keep the match at tick 0 so the first submitted tick is tick 1, and let
    // the trainee (player 1) act first.
    gs.tick = 0
    gs.firstActorThisTick = .player1
    gs.gameStatus = .running
    return Engine(restoring: gs.snapshot(), board: board)
}

private func own(_ gs: inout GameState, _ nodeId: String, _ owner: Owner,
                 influence: Int = 100) {
    if var n = gs.nodes[nodeId] {
        n.owner = owner; n.influence = influence
        gs.nodes[nodeId] = n
    }
}

private func ownEdge(_ gs: inout GameState, _ edgeId: String, _ owner: Owner,
                     flux: Int = 100) {
    let canonical = Legality.canonicalEdgeId(edgeId)
    if var e = gs.edges[canonical] {
        e.owner = owner; e.flux = flux; e.severed = false
        gs.edges[canonical] = e
    }
}

private func setFlux(_ gs: inout GameState, _ player: Player, _ flux: Int) {
    gs.playerStates[player]?.flux = flux
}

private func setCursor(_ gs: inout GameState, _ player: Player,
                       plateau: Int, x: Int, y: Int) {
    gs.playerStates[player]?.cursorPlateau = plateau
    gs.playerStates[player]?.cursorX = x
    gs.playerStates[player]?.cursorY = y
}

// MARK: - Lesson 1: Pulse — First Capture

extension TrainingLesson {
    static let pulseFirstCapture: TrainingLesson = {
        let board = BoardFactory.triad()
        return TrainingLesson(
            id: "pulse-first-capture",
            title: "Pulse: First Capture",
            briefing: "Your anchor at p0x0y0 is fully charged. A neutral node "
                + "sits one link away. Pulse projects influence onto an adjacent "
                + "neutral node to capture it outright.",
            objective: "Capture node p0x1y0 for Player 1.",
            hint: "Pulse targets a node adjacent to your cursor (or any node you "
                + "own with influence >= 40). Your cursor starts on p0x0y0.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                // Default triad start: P1 anchor p0x0y0, cursor there.
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                // Outcome-only: a rejected pulse never sets ownership.
                _ = events
                return state.nodes["p0x1y0"]?.owner == .player1
            }
        )
    }()
}

// MARK: - Lesson 2: Forge — Claim a Link

extension TrainingLesson {
    static let forgeClaimLink: TrainingLesson = {
        let board = BoardFactory.triad()
        return TrainingLesson(
            id: "forge-claim-link",
            title: "Forge: Claim a Link",
            briefing: "You already hold two neighbouring nodes. Forging the link "
                + "between owned nodes claims that edge at full flux — the "
                + "foundation of every sealed cycle.",
            objective: "Forge edge p0x0y0--p0x1y0 so Player 1 owns it.",
            hint: "Forge requires an intra-plateau edge whose first endpoint you "
                + "own and whose second endpoint you own or is neutral.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                own(&gs, "p0x0y0", .player1)   // anchor (already owned)
                own(&gs, "p0x1y0", .player1)
                setCursor(&gs, .player1, plateau: 0, x: 0, y: 0)
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                _ = events
                return state.edges["p0x0y0--p0x1y0"]?.owner == .player1
            }
        )
    }()
}

// MARK: - Lesson 3: Seal — Close a Cycle

extension TrainingLesson {
    static let sealCloseCycle: TrainingLesson = {
        let board = BoardFactory.triad()
        // Face F_p0_x0_y0 boundary (ordered): top, right, bottom, left.
        //   top   = p0x0y0--p0x1y0
        //   right = p0x1y0--p0x1y1
        //   bottom= p0x0y1--p0x1y1
        //   left  = p0x0y0--p0x0y1
        // Three boundary edges are pre-forged; the trainee forges the left
        // edge, then seals the face.
        return TrainingLesson(
            id: "seal-close-cycle",
            title: "Seal: Close a Cycle",
            briefing: "You hold all four corner nodes of a face and three of its "
                + "boundary links. Forge the last link, then seal the cycle to "
                + "claim the territory for good.",
            objective: "Seal face F_p0_x0_y0 for Player 1.",
            hint: "First forge the missing left edge p0x0y0--p0x0y1, then seal "
                + "F_p0_x0_y0. A face is sealable when every boundary edge is "
                + "yours and unsevered.",
            initialSelection: "p0x0y0",
            parMoves: 2,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                own(&gs, "p0x0y0", .player1)
                own(&gs, "p0x1y0", .player1)
                own(&gs, "p0x0y1", .player1)
                own(&gs, "p0x1y1", .player1)
                ownEdge(&gs, "p0x0y0--p0x1y0", .player1)    // top
                ownEdge(&gs, "p0x1y0--p0x1y1", .player1)    // right
                ownEdge(&gs, "p0x0y1--p0x1y1", .player1)    // bottom
                setCursor(&gs, .player1, plateau: 0, x: 0, y: 0)
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                _ = events
                return state.faces["F_p0_x0_y0"]?.sealedBy == .player1
            }
        )
    }()
}

// MARK: - Lesson 4: Reinforce — Anchor Shield

extension TrainingLesson {
    static let reinforceAnchorShield: TrainingLesson = {
        let board = BoardFactory.triad()
        return TrainingLesson(
            id: "reinforce-anchor-shield",
            title: "Reinforce: Anchor Shield",
            briefing: "Your anchor at p0x0y0 is your strongest node. Reinforcing "
                + "it raises it to full influence and opens a brief shield window "
                + "that blunts incoming severs — and regenerates anchor flux.",
            objective: "Reinforce p0x0y0 so it carries an active shield window.",
            hint: "Reinforce targets one of your own anchors. The shield lasts a "
                + "few ticks; check the node's shield window after reinforcing.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                // p0x0y0 is P1's locked anchor by default; cursor starts there.
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                _ = events
                return (state.nodes["p0x0y0"]?.shieldTicks ?? 0) > 0
            }
        )
    }()
}

// MARK: - Lesson 5: Traverse — Cross a Conduit

extension TrainingLesson {
    static let traverseCrossConduit: TrainingLesson = {
        let board = BoardFactory.triad()
        // Conduit p0x0y0--p1x0y0 links plateau 0 to plateau 1 at (0,0).
        // P1 owns the source endpoint (its anchor); traversing projects
        // influence onto the far endpoint and claims it.
        return TrainingLesson(
            id: "traverse-cross-conduit",
            title: "Traverse: Cross a Conduit",
            briefing: "A conduit links your anchor on Alpha to a neutral node on "
                + "Beta. Traversing a conduit pushes influence onto the far "
                + "endpoint and claims the edge — your bridge between plateaus.",
            objective: "Traverse conduit p0x0y0--p1x0y0 and claim p1x0y0 for P1.",
            hint: "Traverse targets a conduit edge whose source endpoint you "
                + "own. Your cursor starts on p0x0y0; the conduit to p1x0y0 is "
                + "one step away.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                // p0x0y0 is P1's anchor by default; cursor starts there.
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                _ = events
                return state.nodes["p1x0y0"]?.owner == .player1
            }
        )
    }()
}

// MARK: - Lesson 6: Sever — Cut an Enemy Line

extension TrainingLesson {
    static let severCutEnemyLine: TrainingLesson = {
        let board = BoardFactory.triad()
        // P2 holds a forged link near its anchor; P1 cuts it.
        return TrainingLesson(
            id: "sever-cut-enemy-line",
            title: "Sever: Cut an Enemy Line",
            briefing: "The opponent has forged a link beside its anchor. Severing "
                + "an enemy edge cuts it, breaks any cycle it belongs to, and "
                + "puts the link into a long cooldown before it can be reclaimed.",
            objective: "Sever edge p0x3y2--p0x3y3 so it is cut.",
            hint: "Sever targets an edge owned by your opponent. It costs more "
                + "flux than most actions but it is the only way to break a "
                + "sealed cycle.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                own(&gs, "p0x3y2", .player2)
                // p0x3y3 is P2's locked anchor by default.
                ownEdge(&gs, "p0x3y2--p0x3y3", .player2)
                setCursor(&gs, .player1, plateau: 0, x: 0, y: 0)
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                _ = events
                return state.edges["p0x3y2--p0x3y3"]?.severed == true
            }
        )
    }()
}

// MARK: - Lesson 7: Counter — Parry a Vector

extension TrainingLesson {
    static let counterParryVector: TrainingLesson = {
        let board = BoardFactory.triad()
        // The counter window requires a live `lastCounterableActions` entry,
        // which is NOT preserved by snapshot restoration (State.init(from:board:)
        // resets it to []). So the engine factory pre-runs tick 1: the opponent
        // forges a counterable edge while the trainee yields. The returned
        // engine is at tick 1 with the forge recorded as counterable; the
        // trainee counters it on tick 2.
        return TrainingLesson(
            id: "counter-parry-vector",
            title: "Counter: Parry a Vector",
            briefing: "The opponent just forged a link. A counter strikes an "
                + "enemy edge in the narrow window after it is forged, draining "
                + "its flux and earning initiative — but only against an action "
                + "from the previous tick.",
            objective: "Counter the opponent's freshly forged edge p0x3y2--p0x3y3.",
            hint: "The opponent's forge is already on record. Counter the edge, "
                + "passing the recorded seq of the forge action. The window "
                + "closes after one tick.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: {
                var eng = setupEngine(board: board) { gs in
                    own(&gs, "p0x3y2", .player2)
                    // p0x3y3 is P2's locked anchor by default.
                    setCursor(&gs, .player1, plateau: 0, x: 0, y: 0)
                    setFlux(&gs, .player1, Balance.maxFlux)
                    setFlux(&gs, .player2, Balance.maxFlux)
                }
                // Tick 1: opponent forges a counterable edge; trainee yields.
                _ = eng.submitTick([.yield_(.player1),
                                    .forge(.player2, "p0x3y2--p0x3y3")])
                return eng
            },
            isComplete: { state, events in
                _ = events
                return (state.playerStates[.player1]?.successfulCounters ?? 0) >= 1
            }
        )
    }()
}

// MARK: - Lesson 8: Yield — Hold Parity

extension TrainingLesson {
    static let yieldHoldParity: TrainingLesson = {
        let board = BoardFactory.triad()
        // A balanced starting position: P1 controls face F_p0_x0_y0, P2
        // controls the symmetric face F_p0_x2_y2. Scores are equal, so the
        // match is in parity. Yielding is a tempo move that holds parity
        // (and earns a parity-hold composure bonus) instead of overextending.
        return TrainingLesson(
            id: "yield-hold-parity",
            title: "Yield: Hold Parity",
            briefing: "The board is balanced — you and the opponent each control "
                + "one face. When the match is in parity, yielding is a sound "
                + "tempo move: it holds the balance and steadies composure rather "
                + "than overextending into a losing exchange.",
            objective: "Yield this tick while the match stays in parity.",
            hint: "Yield passes your turn. Completion requires that you actually "
                + "yield AND that the match remains in parity afterwards.",
            initialSelection: "p0x0y0",
            parMoves: 1,
            board: board,
            makeEngine: { setupEngine(board: board) { gs in
                // P1 controls F_p0_x0_y0 (corner face, area 1).
                own(&gs, "p0x0y0", .player1)
                own(&gs, "p0x1y0", .player1)
                own(&gs, "p0x0y1", .player1)
                own(&gs, "p0x1y1", .player1)
                ownEdge(&gs, "p0x0y0--p0x1y0", .player1)
                ownEdge(&gs, "p0x1y0--p0x1y1", .player1)
                ownEdge(&gs, "p0x0y1--p0x1y1", .player1)
                ownEdge(&gs, "p0x0y0--p0x0y1", .player1)
                // P2 controls the symmetric corner face F_p0_x2_y2.
                own(&gs, "p0x2y2", .player2)
                own(&gs, "p0x3y2", .player2)
                own(&gs, "p0x2y3", .player2)
                own(&gs, "p0x3y3", .player2)
                ownEdge(&gs, "p0x2y2--p0x3y2", .player2)
                ownEdge(&gs, "p0x3y2--p0x3y3", .player2)
                ownEdge(&gs, "p0x2y3--p0x3y3", .player2)
                ownEdge(&gs, "p0x2y2--p0x2y3", .player2)
                setCursor(&gs, .player1, plateau: 0, x: 0, y: 0)
                setFlux(&gs, .player1, Balance.maxFlux)
                setFlux(&gs, .player2, Balance.maxFlux)
            } },
            isComplete: { state, events in
                let yielded = events.contains { $0.type == .yieldIssued && $0.player == .player1 }
                return yielded && Scoring.inParity(state: state)
            }
        )
    }()
}
