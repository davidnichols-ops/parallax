import Foundation

/// Seeded deterministic PRNG (SplitMix64). Used only where the rules explicitly
/// require randomness (bot tie-breaks). Rules logic itself is deterministic.
public struct SeededRNG: Sendable {
    public private(set) var state: UInt64
    public init(seed: UInt64) { self.state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z &>> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z &>> 27)) &* 0x94D049BB133111EB
        return z ^ (z &>> 31)
    }

    public mutating func uniform(lessThan n: Int) -> Int {
        guard n > 0 else { return 0 }
        return Int(next() % UInt64(n))
    }

    /// Seed derived from (matchSeed, tick, seq) — recorded so replays reproduce.
    public static func derive(matchSeed: UInt64, tick: Int, seq: Int) -> SeededRNG {
        var s = matchSeed
        s &+= UInt64(bitPattern: Int64(tick &+ 0x9E3779B9))
        s &+= UInt64(bitPattern: Int64(seq &+ 0x85EBCA77))
        return SeededRNG(seed: s)
    }
}
