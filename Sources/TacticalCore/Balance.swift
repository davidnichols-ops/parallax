import Foundation

/// Versioned balance data. All rules constants live here. Bumping `version`
/// requires a ruleset version flag in every command and snapshot.
public enum Balance {
    public static let version = 1

    // Flux (stored in hundredths; display = value/100)
    public static let maxFlux = 10_000
    public static let baseRegen = 40
    public static let stableNodeRate = 8
    public static let cycleRate = 25
    public static let sectorRate = 6

    // Action costs (hundredths)
    public static let costSelect = 0
    public static let costPulse = 500
    public static let costForge = 400
    public static let costTraverseMin = 600
    public static let costTraversePerCapacity = 1_200   // divided by capacity
    public static let costCounter = 700
    public static let costSever = 1_500
    public static let costSeal = 1_000
    public static let costReinforce = 800
    public static let costFeint = 300
    public static let costYield = 0

    // Action mechanics
    public static let pulseGain = 35
    public static let forgeGain = 50
    public static let conduitInfluenceGain = 50
    public static let counterFluxDamage = 60
    public static let severCooldown = 45
    public static let shieldedSeverCooldown = 15
    public static let shieldWindow = 3
    public static let feintWindow = 2
    public static let feintCounterPenalty = 200
    public static let anchorFluxRegen = 200

    // Scoring
    public static let territoryRate = 4
    public static let cycleRateScore = 5
    public static let counterRate = 2
    public static let cycleBonus = 10

    // Parity / endings
    public static let parityBand = 4
    public static let exhaustionTicks = 40
    public static let matchPressureTarget = 100

    // Composure
    public static let composureParry = 3
    public static let composureParityHold = 2
    public static let composureMiscommand = -4
    public static let composureCycleLost = -6
    public static let composureYieldAlone = -8
    public static let composureOutOfParity = -10

    // Time controls (server-owned, not in sim)
    public static let blitzTimeSeconds = 300
    public static let tournamentTimeSeconds = 1_800
    public static let byoyomiSeconds = 30
    public static let reconnectTicks = 600

    /// Cost of a conduit traversal for a conduit of given capacity, in hundredths.
    public static func traverseCost(capacity: Int) -> Int {
        let raw = costTraversePerCapacity / max(1, capacity)
        return max(costTraverseMin, raw)
    }
}
