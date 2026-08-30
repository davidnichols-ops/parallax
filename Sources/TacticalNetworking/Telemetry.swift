import Foundation
import TacticalCore

/// Telemetry and analytics. Collects match metrics for operations and
/// balance tuning. All data is anonymized — no PII.
public final class TelemetryCollector: @unchecked Sendable {
    private var matchMetrics: [MatchMetrics] = []
    private var balanceMetrics: [String: BalanceMetrics] = [:]
    private var lock = NSLock()

    public init() {}

    public struct MatchMetrics: Sendable, Codable {
        public var matchId: String
        public var boardId: String
        public var matchSeed: UInt64
        public var totalTicks: Int
        public var winner: Int?  // 1, 2, or nil (draw)
        public var endReason: Int?
        public var p1Score: Int
        public var p2Score: Int
        public var p1Moves: Int
        public var p2Moves: Int
        public var p1SealedCycles: Int
        public var p2SealedCycles: Int
        public var p1FluxRemaining: Int
        public var p2FluxRemaining: Int
        public var p1Composure: Int
        public var p2Composure: Int
        public var parityBand: Int
        public var decisiveScore: Bool
        public var timestamp: Date
    }

    public struct BalanceMetrics: Sendable, Codable {
        public var totalMatches: Int = 0
        public var p1WinRate: Double = 0
        public var p2WinRate: Double = 0
        public var drawRate: Double = 0
        public var avgTicksPerMatch: Double = 0
        public var avgScorePerMatch: Double = 0
        public var avgSealedCyclesPerMatch: Double = 0
        public var boardId: String
    }

    public func recordMatch(_ metrics: MatchMetrics) {
        lock.lock()
        defer { lock.unlock() }
        matchMetrics.append(metrics)
        updateBalanceMetrics(metrics)
    }

    private func updateBalanceMetrics(_ m: MatchMetrics) {
        var bm = balanceMetrics[m.boardId, default: BalanceMetrics(boardId: m.boardId)]
        let n = bm.totalMatches + 1
        bm.p1WinRate = (bm.p1WinRate * Double(bm.totalMatches) + (m.winner == 1 ? 1 : 0)) / Double(n)
        bm.p2WinRate = (bm.p2WinRate * Double(bm.totalMatches) + (m.winner == 2 ? 1 : 0)) / Double(n)
        bm.drawRate = (bm.drawRate * Double(bm.totalMatches) + (m.winner == nil ? 1 : 0)) / Double(n)
        bm.avgTicksPerMatch = (bm.avgTicksPerMatch * Double(bm.totalMatches) + Double(m.totalTicks)) / Double(n)
        bm.avgScorePerMatch = (bm.avgScorePerMatch * Double(bm.totalMatches) + Double(m.p1Score + m.p2Score)) / Double(n)
        bm.avgSealedCyclesPerMatch = (bm.avgSealedCyclesPerMatch * Double(bm.totalMatches) + Double(m.p1SealedCycles + m.p2SealedCycles)) / Double(n)
        bm.totalMatches = n
        balanceMetrics[m.boardId] = bm
    }

    public func getBalanceReport(boardId: String) -> BalanceMetrics? {
        lock.lock(); defer { lock.unlock() }
        return balanceMetrics[boardId]
    }

    public func getAllBalanceReports() -> [BalanceMetrics] {
        lock.lock(); defer { lock.unlock() }
        return Array(balanceMetrics.values)
    }

    public func getRecentMatches(limit: Int = 20) -> [MatchMetrics] {
        lock.lock(); defer { lock.unlock() }
        return Array(matchMetrics.suffix(limit))
    }

    public func exportJSON() throws -> Data {
        lock.lock(); defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(matchMetrics)
    }

    /// Check if balance is healthy: win rates near 50/50, reasonable match length.
    public func isBalanceHealthy(boardId: String) -> Bool {
        guard let bm = getBalanceReport(boardId: boardId), bm.totalMatches >= 10 else {
            return true  // Not enough data
        }
        // P1 win rate should be 40-60% (symmetric board).
        let p1Rate = bm.p1WinRate
        if p1Rate < 0.4 || p1Rate > 0.6 { return false }
        // Average match length should be 50-200 ticks.
        if bm.avgTicksPerMatch < 50 || bm.avgTicksPerMatch > 200 { return false }
        return true
    }
}

/// Leaderboard entry with rank, rating, and record.
public struct LeaderboardEntry: Identifiable, Sendable, Codable {
    public let id: String
    public let rank: Int
    public let playerId: String
    public let name: String
    public let rating: Int
    public let wins: Int
    public let losses: Int
    public let draws: Int
    public let matchesPlayed: Int

    public var winRate: Double {
        matchesPlayed > 0 ? Double(wins) / Double(matchesPlayed) : 0
    }
}

/// Leaderboard manager. Sorts players by ELO rating and assigns ranks.
public final class LeaderboardManager: @unchecked Sendable {
    private var entries: [String: LeaderboardEntry] = [:]
    private var lock = NSLock()

    public init() {}

    public func updatePlayer(_ id: String, name: String, rating: Int, wins: Int, losses: Int, draws: Int) {
        lock.lock(); defer { lock.unlock() }
        entries[id] = LeaderboardEntry(
            id: id, rank: 0, playerId: id, name: name,
            rating: rating, wins: wins, losses: losses, draws: draws,
            matchesPlayed: wins + losses + draws
        )
    }

    public func getLeaderboard(limit: Int = 50) -> [LeaderboardEntry] {
        lock.lock(); defer { lock.unlock() }
        var sorted = Array(entries.values).sorted { $0.rating > $1.rating }
        for i in sorted.indices {
            sorted[i] = LeaderboardEntry(
                id: sorted[i].id, rank: i + 1,
                playerId: sorted[i].playerId, name: sorted[i].name,
                rating: sorted[i].rating, wins: sorted[i].wins,
                losses: sorted[i].losses, draws: sorted[i].draws,
                matchesPlayed: sorted[i].matchesPlayed
            )
        }
        return Array(sorted.prefix(limit))
    }

    public func getPlayerRank(_ id: String) -> Int? {
        let board = getLeaderboard(limit: Int.max)
        return board.firstIndex { $0.playerId == id }.map { $0 + 1 }
    }
}
