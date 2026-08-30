import Foundation

/// The action vocabulary (rulebook §5). Each case carries its targeting args.
public enum ActionKind: String, Codable, Sendable, Hashable {
    case select
    case pulse
    case forge
    case traverse
    case counter
    case sever
    case seal
    case reinforce
    case feint
    case yield
    case resign   // meta-command, not a tick action
}

/// An immutable command. `targetTick` is assigned by the authority; clients may
/// leave it 0 for local play (the engine treats 0 as "current tick").
public struct Command: Codable, Sendable, Hashable {
    public let player: Player
    public let action: ActionKind
    public let targetNodeId: String?      // for select/pulse/feint/reinforce
    public let targetEdgeId: String?      // for forge/traverse/counter/sever
    public let candidateCycleId: String?  // for seal (the pre-shown candidate face id)
    public let counteredSeq: Int?         // for counter (the seq being countered)
    public let targetTick: Int

    public init(player: Player, action: ActionKind,
                targetNodeId: String? = nil, targetEdgeId: String? = nil,
                candidateCycleId: String? = nil, counteredSeq: Int? = nil,
                targetTick: Int = 0) {
        self.player = player; self.action = action
        self.targetNodeId = targetNodeId; self.targetEdgeId = targetEdgeId
        self.candidateCycleId = candidateCycleId; self.counteredSeq = counteredSeq
        self.targetTick = targetTick
    }

    /// Convenience constructors.
    public static func select(_ p: Player, _ nodeId: String) -> Command {
        Command(player: p, action: .select, targetNodeId: nodeId)
    }
    public static func pulse(_ p: Player, _ nodeId: String) -> Command {
        Command(player: p, action: .pulse, targetNodeId: nodeId)
    }
    public static func forge(_ p: Player, _ edgeId: String) -> Command {
        Command(player: p, action: .forge, targetEdgeId: edgeId)
    }
    public static func traverse(_ p: Player, _ edgeId: String) -> Command {
        Command(player: p, action: .traverse, targetEdgeId: edgeId)
    }
    public static func counter(_ p: Player, _ edgeId: String, counteredSeq: Int) -> Command {
        Command(player: p, action: .counter, targetEdgeId: edgeId, counteredSeq: counteredSeq)
    }
    public static func sever(_ p: Player, _ edgeId: String) -> Command {
        Command(player: p, action: .sever, targetEdgeId: edgeId)
    }
    public static func seal(_ p: Player, _ faceId: String) -> Command {
        Command(player: p, action: .seal, candidateCycleId: faceId)
    }
    public static func reinforce(_ p: Player, _ nodeId: String) -> Command {
        Command(player: p, action: .reinforce, targetNodeId: nodeId)
    }
    public static func feint(_ p: Player, _ nodeId: String) -> Command {
        Command(player: p, action: .feint, targetNodeId: nodeId)
    }
    public static func yield_(_ p: Player) -> Command {
        Command(player: p, action: .yield)
    }
    public static func resign(_ p: Player) -> Command {
        Command(player: p, action: .resign)
    }
}

/// Rejection reasons (typed, exhaustive).
public enum RejectionReason: String, Codable, Sendable, Hashable {
    case gameNotRunning
    case insufficientFlux
    case invalidTarget
    case notOwnedByPlayer
    case notEnemyOwned
    case edgeSevered
    case conduitOccluded
    case notAdjacent
    case counterWindowExpired
    case noCandidateCycle
    case cycleAlreadySealed
    case cycleBroken
    case illegalAction
    case notAnAnchor
    case capacityContested
}

/// Pre-commitment projection (rulebook §9).
public struct Projection: Sendable {
    public let legal: Bool
    public let cost: Int      // hundredths
    public let reason: RejectionReason?
}
