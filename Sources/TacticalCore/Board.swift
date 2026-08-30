import Foundation

/// Ownership of a node or edge. Order is canonical for encoding.
public enum Owner: Int, Codable, Sendable, Hashable {
    case neutral = 0
    case player1 = 1
    case player2 = 2
    case severed = 3   // edges only; nodes never use this

    public static func < (lhs: Owner, rhs: Owner) -> Bool { lhs.rawValue < rhs.rawValue }

    public var opponent: Owner {
        switch self {
        case .player1: return .player2
        case .player2: return .player1
        default: return .neutral
        }
    }

    public var isPlayer: Bool { self == .player1 || self == .player2 }

    public var label: String {
        switch self {
        case .neutral: return "Neutral"
        case .player1: return "P1"
        case .player2: return "P2"
        case .severed: return "Severed"
        }
    }
}

public enum Player: Int, Codable, Sendable, Hashable {
    case player1 = 1
    case player2 = 2

    public static func < (lhs: Player, rhs: Player) -> Bool { lhs.rawValue < rhs.rawValue }

    public var owner: Owner { Owner(rawValue: rawValue)! }
    public var opponent: Player { self == .player1 ? .player2 : .player1 }
    public var label: String { self == .player1 ? "P1" : "P2" }
}

public enum NodeKind: Int, Codable, Sendable {
    case standard = 0
    case anchor = 1
    case conduit = 2
}

public enum EdgeKind: Int, Codable, Sendable {
    case intra = 0
    case conduit = 1
}

public enum FaceKind: Int, Codable, Sendable {
    case plateau = 0
    case cross = 1
}

/// A node. Stable IDs; rules never infer logic from rendered coordinates.
public struct NodeDef: Codable, Sendable, Hashable {
    public let id: String
    public let plateau: Int
    public let x: Int
    public let y: Int
    public let kind: NodeKind
    public init(id: String, plateau: Int, x: Int, y: Int, kind: NodeKind = .standard) {
        self.id = id; self.plateau = plateau; self.x = x; self.y = y; self.kind = kind
    }
}

/// An edge. Unordered endpoints; `id` is the canonical sorted join.
public struct EdgeDef: Codable, Sendable, Hashable {
    public let id: String
    public let u: String
    public let v: String
    public let kind: EdgeKind
    public let capacity: Int
    public init(u: String, v: String, kind: EdgeKind, capacity: Int = 1) {
        let pair = [u, v].sorted()
        self.id = pair[0] + "--" + pair[1]
        self.u = pair[0]
        self.v = pair[1]
        self.kind = kind
        self.capacity = capacity
    }
}

/// A face — the only unit of territory. Boundary is an ordered list of edge ids
/// forming a simple cycle.
public struct FaceDef: Codable, Sendable, Hashable {
    public let id: String
    public let boundary: [String]   // edge ids, ordered
    public let plateau: Int         // -1 for cross-plateau sectors
    public let area: Int
    public let kind: FaceKind
    public init(id: String, boundary: [String], plateau: Int, area: Int, kind: FaceKind = .plateau) {
        self.id = id; self.boundary = boundary; self.plateau = plateau
        self.area = area; self.kind = kind
    }
}

public struct PlateauDef: Codable, Sendable, Hashable {
    public let index: Int
    public let name: String
    public let nodeIds: [String]
    public let faceIds: [String]
}

public struct AnchorSpec: Codable, Sendable, Hashable {
    public let player1: [String]
    public let player2: [String]
}

/// A versioned, validated board definition.
public struct BoardDefinition: Codable, Sendable, Hashable {
    public let id: String
    public let version: Int
    public let plateaus: [PlateauDef]
    public let nodes: [NodeDef]
    public let edges: [EdgeDef]
    public let faces: [FaceDef]
    public let anchors: AnchorSpec
    public let rulesetVersion: Int

    public init(id: String, version: Int, plateaus: [PlateauDef], nodes: [NodeDef],
                edges: [EdgeDef], faces: [FaceDef], anchors: AnchorSpec,
                rulesetVersion: Int = Balance.version) {
        self.id = id; self.version = version; self.plateaus = plateaus
        self.nodes = nodes; self.edges = edges; self.faces = faces
        self.anchors = anchors; self.rulesetVersion = rulesetVersion
    }

    /// Lookup maps (built once).
    public var nodeMap: [String: NodeDef] {
        Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
    }
    public var edgeMap: [String: EdgeDef] {
        Dictionary(uniqueKeysWithValues: edges.map { ($0.id, $0) })
    }
    public var faceMap: [String: FaceDef] {
        Dictionary(uniqueKeysWithValues: faces.map { ($0.id, $0) })
    }
    /// Edges incident to each node id.
    public var incidence: [String: [String]] {
        var inc: [String: [String]] = [:]
        for e in edges {
            inc[e.u, default: []].append(e.id)
            inc[e.v, default: []].append(e.id)
        }
        return inc
    }
}
