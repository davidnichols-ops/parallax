import Foundation
import CryptoKit

/// Canonical encoding + state hashing (rulebook §1). The encoding is
/// platform-independent: sorted keys, fixed-width integer fields, UTF-8 strings.
/// It must match across client, server, replay, arm64, and x86_64.
public enum CanonicalEncoding {

    /// Canonical JSON with sorted keys and no whitespace. Foundation's
    /// `JSONEncoder.outputFormatting = [.sortedKeys]` gives deterministic key
    /// order; we additionally require stable integer encoding (Int → fixed).
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.keyEncodingStrategy = .useDefaultKeys
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(value)
    }

    /// SHA-256 over the canonical encoding of a snapshot.
    public static func snapshotHash(_ s: Snapshot) -> String {
        guard let data = try? encode(s) else { return "<encode-failed>" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 over the canonical encoding of the event log (replay integrity).
    public static func eventLogHash(_ log: EventLog) -> String {
        struct Wrapper: Encodable { let events: [Event] }
        guard let data = try? encode(Wrapper(events: log.events)) else { return "<encode-failed>" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// A content hash covering only game-relevant state (nodes, edges, faces,
    /// player flux/score, parity). Excludes bookkeeping fields that change every
    /// tick regardless of play (tick counter, initiative flip, exhaustion counter)
    /// and psychological metrics that fluctuate continuously (composure). Used
    /// for board-exhaustion detection so that a tick which only advanced the
    /// counter or adjusted composure is correctly judged "no meaningful change".
    public static func contentHash(_ s: Snapshot) -> String {
        struct Content: Encodable {
            let nodes: [String: NodeState]
            let edges: [String: EdgeState]
            let faces: [String: FaceState]
            let p1Flux: Int
            let p2Flux: Int
            let p1Score: Int
            let p2Score: Int
            let parity: Int
        }
        let c = Content(
            nodes: s.nodes, edges: s.edges, faces: s.faces,
            p1Flux: s.player1State.flux,
            p2Flux: s.player2State.flux,
            p1Score: s.player1State.score,
            p2Score: s.player2State.score,
            parity: s.parity
        )
        guard let data = try? encode(c) else { return "<encode-failed>" }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
