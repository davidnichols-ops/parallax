import Foundation

/// Append-only domain events. Every state change emits one. The event log is
/// the replay primitive (rulebook §1, master prompt §39).
public enum EventType: String, Codable, Sendable, Hashable {
    case cursorMoved
    case nodePulsed
    case nodeContested
    case linkForged
    case conduitTraversed
    case conduitContested
    case vectorCountered
    case counterFailed
    case linkSevered
    case cycleSealed
    case anchorReinforced
    case feintRegistered
    case opponentFeinted
    case actionRejected
    case yieldIssued
    case scoreChanged
    case composureChanged
    case parityChanged
    case edgeRestored
    case cycleBroken
    case matchWon
    case matchDrawn
    case matchVoided
    case tickResolved
    case botMoveChosen   // records the bot's chosen command (master prompt §27)
}

public struct Event: Codable, Sendable, Hashable {
    public let seq: Int
    public let tick: Int
    public let type: EventType
    public let player: Player?
    public let payload: [String: String]   // sorted-key, string-valued for canonical encoding
    public init(seq: Int, tick: Int, type: EventType, player: Player?,
                payload: [String: String] = [:]) {
        self.seq = seq; self.tick = tick; self.type = type; self.player = player
        self.payload = payload
    }
}

/// An append-only event log with monotonic sequence numbers.
public struct EventLog: Sendable {
    public private(set) var events: [Event] = []
    public private(set) var nextSeq: Int = 0
    public init() {}

    @discardableResult
    public mutating func append(_ type: EventType, tick: Int, player: Player?,
                                payload: [String: String] = [:]) -> Event {
        let e = Event(seq: nextSeq, tick: tick, type: type, player: player, payload: payload)
        nextSeq += 1
        events.append(e)
        return e
    }

    public func suffix(fromTick tick: Int) -> [Event] {
        events.filter { $0.tick >= tick }
    }
}
