import Foundation

/// Scoring, parity, and composure (rulebook §8, §10, §11).
public enum Scoring {

    /// Recompute a player's raw score (cumulative pressure).
    /// Includes the one-time cycle bonus for each sealed cycle (rulebook §8.3).
    public static func computeScore(_ player: Player, state: GameState) -> Int {
        let area = Territory.controlledArea(player, state: state)
        let cycles = Territory.sealedFaces(player, state: state).count
        let counters = state.playerStates[player]?.successfulCounters ?? 0
        let sealedCycleCount = state.playerStates[player]?.sealedCycles ?? 0
        let objective = objectiveBonus(player, state: state)
        return Balance.territoryRate * area
             + Balance.cycleRateScore * cycles
             + Balance.counterRate * counters
             + Balance.cycleBonus * sealedCycleCount
             + objective
    }

    /// Mode-specific objective bonus. Default: control of any central face
    /// (a face whose id contains "x1_y1" on plateau 0) grants +5. Authorable.
    public static func objectiveBonus(_ player: Player, state: GameState) -> Int {
        let controlled = Set(Territory.controlledFaces(player, state: state))
        var bonus = 0
        for f in state.board.faces where f.plateau == 0 && f.id.contains("x1_y1") {
            if controlled.contains(f.id) { bonus += 5 }
        }
        return bonus
    }

    /// Match-pressure display value (0..100).
    public static func pressure(_ player: Player, state: GameState) -> Int {
        min(Balance.matchPressureTarget, computeScore(player, state: state))
    }

    /// Parity = score(P1) - score(P2).
    public static func parity(state: GameState) -> Int {
        computeScore(.player1, state: state) - computeScore(.player2, state: state)
    }

    /// In parity iff |parity| <= band and neither player controls a winning-line
    /// face (a face whose control would push score >= 100). For the first slice,
    /// "winning-line face" is approximated as: a face whose control would raise
    /// the controller's pressure to 100.
    public static func inParity(state: GameState) -> Bool {
        let p = parity(state: state)
        if abs(p) > Balance.parityBand { return false }
        // Check no player is one face away from 100.
        for player in [Player.player1, .player2] {
            let cur = pressure(player, state: state)
            if cur >= Balance.matchPressureTarget - 4 { return false }
        }
        return true
    }

    /// Apply composure deltas for the tick's events. Pure: returns new composure.
    public static func applyComposure(_ player: Player, state: GameState,
                                      events: [Event]) -> Int {
        var c = state.playerStates[player]?.composure ?? 50
        for e in events where e.player == player {
            switch e.type {
            case .vectorCountered: c += Balance.composureParry
            case .actionRejected: c += Balance.composureMiscommand
            case .cycleBroken: c += Balance.composureCycleLost
            default: break
            }
        }
        // Tick-level: parity hold / out of parity / yield-alone.
        if Scoring.inParity(state: state) { c += Balance.composureParityHold }
        else if abs(parity(state: state)) > Balance.parityBand {
            c += Balance.composureOutOfParity
        }
        c = max(0, min(100, c))
        return c
    }
}
