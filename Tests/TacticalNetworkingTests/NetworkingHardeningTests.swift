import XCTest
@testable import TacticalNetworking
import TacticalCore

final class NetworkingHardeningTests: XCTestCase {

    var board: BoardDefinition!
    var server: MatchServer!

    override func setUp() {
        super.setUp()
        board = BoardFactory.triad()
        server = MatchServer(storage: InMemoryStorage(), config: MatchServer.ServerConfig())
    }

    @discardableResult
    func makeMatch(seed: UInt64 = 0xABCD) -> (matchId: String, p1: String, p2: String) {
        _ = server.registerPlayer(id: "p1", name: "Alice")
        _ = server.registerPlayer(id: "p2", name: "Bob")
        let mid = server.createMatch(player1Id: "p1", player2Id: "p2",
                                     board: board, seed: seed)!
        return (mid, "p1", "p2")
    }

    // MARK: - Durable identifiers + reconnect

    func testCreateMatchAssignsDurableSessionIdsAndSides() {
        let (mid, p1, p2) = makeMatch()
        let s1 = server.session(forPlayer: p1, inMatch: mid)
        let s2 = server.session(forPlayer: p2, inMatch: mid)
        XCTAssertNotNil(s1)
        XCTAssertNotNil(s2)
        XCTAssertEqual(s1?.assignedSide, .player1)
        XCTAssertEqual(s2?.assignedSide, .player2)
        XCTAssertNotEqual(s1?.sessionId, s2?.sessionId)
        XCTAssertTrue(s1?.sessionId.hasPrefix("sess_") ?? false)
        XCTAssertEqual(server.activeMatchCount, 1)
    }

    func testReconnectReturnsCurrentAuthoritativeSnapshot() {
        let (mid, p1, _) = makeMatch()
        let token = server.session(forPlayer: p1, inMatch: mid)!.sessionId

        // First command is accepted (queued); second triggers the tick advance.
        let r1 = server.submitCommand(playerId: "p1", command: .pulse(.player1, "p0x1y0"))
        if case .accepted = r1 {} else { XCTFail("expected accepted, got \(r1)") }
        let r2 = server.submitCommand(playerId: "p2", command: .yield_(.player2))
        if case .tickAdvanced = r2 {} else { XCTFail("expected tickAdvanced, got \(r2)") }

        server.disconnect(sessionId: token)
        let resume = server.reconnect(sessionId: token)
        guard case .resumed(let info) = resume else {
            return XCTFail("expected .resumed, got \(resume)")
        }
        XCTAssertEqual(info.matchId, mid)
        XCTAssertEqual(info.assignedSide, .player1)
        XCTAssertEqual(info.tick, 1)
        XCTAssertEqual(info.matchStatus, .running)
        XCTAssertEqual(info.snapshot, server.getMatchState(matchId: mid))
    }

    func testReconnectWithInvalidTokenIsRejected() {
        makeMatch()
        let resume = server.reconnect(sessionId: "sess_bogus")
        if case .invalidToken = resume {} else {
            XCTFail("expected .invalidToken, got \(resume)")
        }
    }

    func testReconnectAfterMatchEndedReportsEndedStatus() {
        let (mid, p1, p2) = makeMatch()
        // Resign is a tick command: it ends the match only when the tick
        // advances (both players submit). P1 resigns, P2 yields → tick resolves
        // → match ends.
        _ = server.submitCommand(playerId: p1, command: .resign(.player1))
        let r2 = server.submitCommand(playerId: p2, command: .yield_(.player2))
        if case .matchEnded = r2 {} else { XCTFail("expected matchEnded, got \(r2)") }

        let token = server.session(forPlayer: p1, inMatch: mid)!.sessionId
        let resume = server.reconnect(sessionId: token)
        guard case .resumed(let info) = resume else {
            return XCTFail("expected .resumed, got \(resume)")
        }
        XCTAssertEqual(info.matchStatus, .ended)
        XCTAssertNotNil(info.snapshot.winner)
    }

    // MARK: - Server-authoritative command validation

    func testRejectsCommandClaimingOpponentSide() {
        let (_, p1, _) = makeMatch()
        let r = server.submitCommand(playerId: p1, command: .pulse(.player2, "p0x1y0"))
        guard case .rejected(let reason) = r else {
            return XCTFail("expected .rejected, got \(r)")
        }
        XCTAssertTrue(reason.contains("assigned side"), "reason should mention side binding: \(reason)")
    }

    func testRejectsStaleCommand() {
        let (mid, p1, p2) = makeMatch()
        // Advance to tick 1, then tick 2, so current tick is 2.
        _ = server.submitCommand(playerId: p1, command: .yield_(.player1))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))
        _ = server.submitCommand(playerId: p1, command: .yield_(.player1))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))
        XCTAssertEqual(server.getMatchState(matchId: mid)?.tick, 2)

        // A command explicitly targeting tick 1 (now in the past) is stale.
        let stale = Command(player: .player1, action: .yield, targetTick: 1)
        let r = server.submitCommand(playerId: p1, command: stale)
        guard case .rejected(let reason) = r else {
            return XCTFail("expected .rejected for stale, got \(r)")
        }
        XCTAssertTrue(reason.contains("stale"), "reason should mention stale: \(reason)")
    }

    func testRejectsFarFutureCommand() {
        let (_, p1, _) = makeMatch()
        let future = Command(player: .player1, action: .yield, targetTick: 5)
        let r = server.submitCommand(playerId: p1, command: future)
        guard case .rejected(let reason) = r else {
            return XCTFail("expected .rejected for future, got \(r)")
        }
        XCTAssertTrue(reason.contains("future"), "reason should mention future: \(reason)")
    }

    func testRejectsDuplicateCommandSameTick() {
        let (_, p1, _) = makeMatch()
        let first = server.submitCommand(playerId: p1, command: .yield_(.player1))
        if case .accepted = first {} else { XCTFail("expected accepted, got \(first)") }
        let dup = server.submitCommand(playerId: p1, command: .pulse(.player1, "p0x1y0"))
        guard case .rejected(let reason) = dup else {
            return XCTFail("expected .rejected for duplicate, got \(dup)")
        }
        XCTAssertTrue(reason.contains("already submitted"), "reason should mention duplicate: \(reason)")
    }

    func testRejectsIllegalCommand() {
        let (_, p1, _) = makeMatch()
        let r = server.submitCommand(playerId: p1, command: .pulse(.player1, "no_such_node"))
        guard case .rejected = r else {
            return XCTFail("expected .rejected for illegal, got \(r)")
        }
    }

    func testRejectsCommandForUnregisteredPlayer() {
        makeMatch()
        let r = server.submitCommand(playerId: "ghost", command: .yield_(.player1))
        if case .error = r {} else { XCTFail("expected .error, got \(r)") }
    }

    func testRejectsCommandWhenMatchNotRunning() {
        let (_, p1, p2) = makeMatch()
        // End the match: P1 resigns, P2 yields → tick resolves → match ends.
        _ = server.submitCommand(playerId: p1, command: .resign(.player1))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))
        // Now the match is over; further commands must be rejected as .error
        // (no active match / not running).
        let r = server.submitCommand(playerId: p1, command: .yield_(.player1))
        if case .error = r {} else { XCTFail("expected .error after match end, got \(r)") }
    }

    // MARK: - Ordering + deterministic framing

    func testTickFramesAppendInTickOrder() {
        let (mid, p1, p2) = makeMatch()
        _ = server.submitCommand(playerId: p1, command: .pulse(.player1, "p0x1y0"))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))
        _ = server.submitCommand(playerId: p1, command: .yield_(.player1))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))

        let frames = server.getMatchFrames(matchId: mid)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].tick, 1)
        XCTAssertEqual(frames[1].tick, 2)
        XCTAssertLessThan(frames[0].tick, frames[1].tick)
    }

    func testTickFrameCarriesSnapshotHashAndEvents() {
        let (mid, p1, p2) = makeMatch()
        _ = server.submitCommand(playerId: p1, command: .pulse(.player1, "p0x1y0"))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))

        let frame = server.getMatchFrames(matchId: mid).first!
        XCTAssertEqual(frame.tick, 1)
        XCTAssertEqual(frame.snapshot.tick, 1)
        XCTAssertEqual(frame.snapshotHash, CanonicalEncoding.snapshotHash(frame.snapshot))
        XCTAssertFalse(frame.events.isEmpty)
        XCTAssertTrue(frame.events.contains { $0.type == .nodePulsed })
        XCTAssertTrue(frame.events.contains { $0.type == .tickResolved })
    }

    func testFrameSnapshotMatchesServerAuthoritativeState() {
        let (mid, p1, p2) = makeMatch()
        _ = server.submitCommand(playerId: p1, command: .pulse(.player1, "p0x1y0"))
        _ = server.submitCommand(playerId: p2, command: .yield_(.player2))

        let frame = server.getMatchFrames(matchId: mid).first!
        let authoritative = server.getMatchState(matchId: mid)!
        XCTAssertEqual(frame.snapshot, authoritative)
    }

    func testFramesReconstructMatchDeterministically() {
        // The frame stream must be sufficient to reconstruct the match: each
        // frame's snapshot hash must equal what a fresh engine produces when
        // fed the frame's commands in order. This is the replay/spectator
        // contract.
        let (mid, p1, p2) = makeMatch(seed: 0xDEAD)
        let cmds: [(Command, Command)] = [
            (.pulse(.player1, "p0x1y0"), .yield_(.player2)),
            (.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)),
            (.yield_(.player1), .yield_(.player2))
        ]
        for (c1, c2) in cmds {
            _ = server.submitCommand(playerId: p1, command: c1)
            _ = server.submitCommand(playerId: p2, command: c2)
        }

        let frames = server.getMatchFrames(matchId: mid)
        XCTAssertEqual(frames.count, cmds.count)

        // Reconstruct from a fresh engine using only the frame commands.
        var recon = Engine(board: board, matchSeed: 0xDEAD)
        for frame in frames {
            let (snap, _) = recon.submitTick([frame.p1Command, frame.p2Command])
            XCTAssertEqual(CanonicalEncoding.snapshotHash(snap), frame.snapshotHash,
                           "reconstructed tick \(frame.tick) hash must match the frame hash")
        }
        // Final reconstructed state must match the server's final state.
        XCTAssertEqual(recon.state.snapshot(), server.getMatchState(matchId: mid))
    }

    func testGetFramesSinceTickReturnsOnlyMissedFrames() {
        let (mid, p1, p2) = makeMatch()
        for _ in 0..<3 {
            _ = server.submitCommand(playerId: p1, command: .yield_(.player1))
            _ = server.submitCommand(playerId: p2, command: .yield_(.player2))
        }
        // A spectator that last saw tick 1 should get frames for ticks >= 2.
        let missed = server.getMatchFrames(matchId: mid, sinceTick: 2)
        XCTAssertEqual(missed.count, 2)
        XCTAssertEqual(missed.first?.tick, 2)
        XCTAssertEqual(missed.last?.tick, 3)
    }

    // MARK: - InMemoryStorage history correctness

    func testInMemoryStorageRecordsHistoryForBothPlayers() {
        let storage = InMemoryStorage()
        let s = MatchServer(storage: storage)
        _ = s.registerPlayer(id: "p1", name: "Alice")
        _ = s.registerPlayer(id: "p2", name: "Bob")
        let mid = s.createMatch(player1Id: "p1", player2Id: "p2",
                                board: board, seed: 1)!
        // End the match via resign + yield so a result is saved.
        _ = s.submitCommand(playerId: "p1", command: .resign(.player1))
        _ = s.submitCommand(playerId: "p2", command: .yield_(.player2))

        // Both players must have the match in their history (the old code
        // hardcoded "p1" and only recorded history for that literal).
        let h1 = storage.getPlayerHistory("p1", limit: 10)
        let h2 = storage.getPlayerHistory("p2", limit: 10)
        XCTAssertTrue(h1.contains(mid), "p1 history must contain the match id")
        XCTAssertTrue(h2.contains(mid), "p2 history must contain the match id")
    }

    func testMatchResultSnapshotIsPersisted() {
        let storage = InMemoryStorage()
        let s = MatchServer(storage: storage)
        _ = s.registerPlayer(id: "p1", name: "Alice")
        _ = s.registerPlayer(id: "p2", name: "Bob")
        let mid = s.createMatch(player1Id: "p1", player2Id: "p2",
                                board: board, seed: 1)!
        _ = s.submitCommand(playerId: "p1", command: .resign(.player1))
        _ = s.submitCommand(playerId: "p2", command: .yield_(.player2))
        let saved = storage.getMatchResult(mid)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.winner, .player2)
        XCTAssertEqual(saved?.endReason, .resignation)
    }

    // MARK: - NetMessage round-trip encoding

    func testMatchStartRoundTripsWithSnapshot() throws {
        let snap = Engine(board: board, matchSeed: 1).state.snapshot()
        let msg = NetMessage.matchStart(
            matchId: "m1", sessionId: "sess_1", boardId: board.id,
            matchSeed: 1, assignedSide: 1, snapshot: snap)
        let data = try msg.encode()
        let decoded = try NetMessage.decode(data)
        guard case .matchStart(let mid, let sid, let bid, let seed, let side, let dsnap) = decoded else {
            return XCTFail("decoded to wrong case: \(decoded)")
        }
        XCTAssertEqual(mid, "m1")
        XCTAssertEqual(sid, "sess_1")
        XCTAssertEqual(bid, board.id)
        XCTAssertEqual(seed, 1)
        XCTAssertEqual(side, 1)
        XCTAssertEqual(dsnap, snap)
    }

    func testTickFrameRoundTripsWithCommandsSnapshotAndEvents() throws {
        var engine = Engine(board: board, matchSeed: 7)
        let c1 = Command.pulse(.player1, "p0x1y0")
        let c2 = Command.yield_(.player2)
        let (snap, events) = engine.submitTick([c1, c2])
        let hash = CanonicalEncoding.snapshotHash(snap)
        let msg = NetMessage.tickFrame(
            matchId: "m1", tick: snap.tick, p1Command: c1, p2Command: c2,
            snapshot: snap, snapshotHash: hash, events: events)
        let data = try msg.encode()
        let decoded = try NetMessage.decode(data)
        guard case .tickFrame(let mid, let tick, let dc1, let dc2, let dsnap, let dhash, let devents) = decoded else {
            return XCTFail("decoded to wrong case: \(decoded)")
        }
        XCTAssertEqual(mid, "m1")
        XCTAssertEqual(tick, snap.tick)
        XCTAssertEqual(dc1, c1)
        XCTAssertEqual(dc2, c2)
        XCTAssertEqual(dsnap, snap)
        XCTAssertEqual(dhash, hash)
        XCTAssertEqual(devents.count, events.count)
    }

    func testReconnectAndReconnectAckRoundTrip() throws {
        let reconnect = NetMessage.reconnect(sessionId: "sess_xyz")
        let rData = try reconnect.encode()
        if case .reconnect(let sid) = try NetMessage.decode(rData) {
            XCTAssertEqual(sid, "sess_xyz")
        } else { XCTFail("reconnect round-trip failed") }

        let snap = Engine(board: board, matchSeed: 1).state.snapshot()
        let ack = NetMessage.reconnectAck(
            matchId: "m1", assignedSide: 2, tick: 5, snapshot: snap, status: 0)
        let aData = try ack.encode()
        if case .reconnectAck(let mid, let side, let tick, let dsnap, let status) = try NetMessage.decode(aData) {
            XCTAssertEqual(mid, "m1")
            XCTAssertEqual(side, 2)
            XCTAssertEqual(tick, 5)
            XCTAssertEqual(dsnap, snap)
            XCTAssertEqual(status, 0)
        } else { XCTFail("reconnectAck round-trip failed") }
    }

    func testSnapshotMessageRoundTrip() throws {
        let snap = Engine(board: board, matchSeed: 1).state.snapshot()
        let msg = NetMessage.snapshot(matchId: "m1", tick: 3, snapshot: snap)
        let data = try msg.encode()
        if case .snapshot(let mid, let tick, let dsnap) = try NetMessage.decode(data) {
            XCTAssertEqual(mid, "m1")
            XCTAssertEqual(tick, 3)
            XCTAssertEqual(dsnap, snap)
        } else { XCTFail("snapshot round-trip failed") }
    }

    func testCommandMessageRoundTrip() throws {
        let cmd = Command.forge(.player1, "p0x0y0--p0x1y0")
        let msg = NetMessage.command(matchId: "m1", sessionId: "sess_1", command: cmd)
        let data = try msg.encode()
        if case .command(let mid, let sid, let dcmd) = try NetMessage.decode(data) {
            XCTAssertEqual(mid, "m1")
            XCTAssertEqual(sid, "sess_1")
            XCTAssertEqual(dcmd, cmd)
        } else { XCTFail("command round-trip failed") }
    }

    func testLegacyMessagesStillDecode() throws {
        // Backward compatibility: the legacy cases must still round-trip.
        let hello = NetMessage.hello(version: "1", playerId: "p", name: "n")
        if case .hello(let v, let p, let n) = try NetMessage.decode(try hello.encode()) {
            XCTAssertEqual(v, "1"); XCTAssertEqual(p, "p"); XCTAssertEqual(n, "n")
        } else { XCTFail("hello round-trip failed") }

        let init_ = NetMessage.matchInit(boardId: "triad", matchSeed: 1, p1Id: "1", p2Id: "2")
        if case .matchInit(let b, let s, let a, let b2) = try NetMessage.decode(try init_.encode()) {
            XCTAssertEqual(b, "triad"); XCTAssertEqual(s, 1); XCTAssertEqual(a, "1"); XCTAssertEqual(b2, "2")
        } else { XCTFail("matchInit round-trip failed") }

        let tick = NetMessage.tickCommand(tick: 1, player: 1, action: "yield",
                                          targetNodeId: nil, targetEdgeId: nil, candidateCycleId: nil)
        if case .tickCommand(let t, let p, let a, _, _, _) = try NetMessage.decode(try tick.encode()) {
            XCTAssertEqual(t, 1); XCTAssertEqual(p, 1); XCTAssertEqual(a, "yield")
        } else { XCTFail("tickCommand round-trip failed") }
    }

    // MARK: - Matchmaking still works

    func testMatchmakingPairsTwoQueuedPlayers() {
        _ = server.registerPlayer(id: "p1", name: "Alice")
        _ = server.registerPlayer(id: "p2", name: "Bob")
        XCTAssertTrue(server.enqueueMatchmaking(playerId: "p1"))
        XCTAssertEqual(server.pendingQueueCount, 1)
        XCTAssertTrue(server.enqueueMatchmaking(playerId: "p2"))
        // The second enqueue triggers matchmaking; both should be paired.
        XCTAssertEqual(server.pendingQueueCount, 0)
        XCTAssertEqual(server.activeMatchCount, 1)
        XCTAssertNotNil(server.getPlayerSession("p1")?.currentMatchId)
        XCTAssertNotNil(server.getPlayerSession("p2")?.currentMatchId)
    }

    func testCreateMatchRejectsPlayerAlreadyInMatch() {
        _ = server.registerPlayer(id: "p1", name: "Alice")
        _ = server.registerPlayer(id: "p2", name: "Bob")
        _ = server.registerPlayer(id: "p3", name: "Carol")
        _ = server.createMatch(player1Id: "p1", player2Id: "p2", board: board, seed: 1)
        // p1 is already in a match; a second match involving p1 must be refused.
        let second = server.createMatch(player1Id: "p1", player2Id: "p3", board: board, seed: 2)
        XCTAssertNil(second)
    }
}
