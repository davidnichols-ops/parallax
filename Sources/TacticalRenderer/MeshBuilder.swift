import Foundation
import simd
import TacticalCore

/// Converts a BoardDefinition + GameState into renderer instance data.
/// Board layout: a compact tabletop lattice, read from a fixed oblique view.
/// Each plateau is a shallow physical layer above the table, like a futuristic
/// connect-four board rather than a wall of floating presentation panels.
public struct MeshBuilder {

    /// Vertical separation between tactical layers.
    public static let plateauSpacing: Float = 1.25
    /// Horizontal scale per grid unit.
    public static let gridScale: Float = 1.5
    /// World position for a node definition.
    public static func nodePosition(_ def: NodeDef, board: BoardDefinition) -> SIMD3<Float> {
        let x = Float(def.x) * gridScale
        let z = Float(def.y) * gridScale
        let panelNodes = board.nodes.filter { $0.plateau == def.plateau }
        let minX = panelNodes.map(\.x).min() ?? 0
        let maxX = panelNodes.map(\.x).max() ?? 0
        let minY = panelNodes.map(\.y).min() ?? 0
        let maxY = panelNodes.map(\.y).max() ?? 0
        let centeredX = x - Float(minX + maxX) * gridScale * 0.5
        let centeredZ = z - Float(minY + maxY) * gridScale * 0.5
        let centeredPanel = Float(def.plateau) - Float(board.plateaus.count - 1) * 0.5
        return SIMD3<Float>(centeredX, centeredPanel * plateauSpacing, -centeredZ)
    }

    /// Node radius by kind.
    public static func nodeRadius(_ kind: NodeKind) -> Float {
        switch kind {
        case .anchor: return 0.45
        case .conduit: return 0.38
        case .standard: return 0.30
        }
    }

    /// Build node instances from board + state.
    public static func nodeInstances(board: BoardDefinition, state: GameState,
                                     selectedNodeId: String? = nil) -> [NodeInstance] {
        board.nodes.map { def in
            let pos = nodePosition(def, board: board)
            let ns = state.nodes[def.id] ?? NodeState()
            let color = OwnershipPalette.color(for: ns.owner)
            let radius = nodeRadius(def.kind)
            let selected: Float = (def.id == selectedNodeId) ? 1.0 : 0.0
            let locked: Float = ns.locked ? 1.0 : 0.0
            let glow: Float = ns.influence >= 100 ? 0.3 : Float(ns.influence) / 100.0 * 0.2
            return NodeInstance(position: pos, radius: radius, color: color,
                                glow: glow, selected: selected, locked: locked)
        }
    }

    /// Build edge instances from board + state.
    public static func edgeInstances(board: BoardDefinition, state: GameState) -> [EdgeInstance] {
        var result = board.edges.map { def in
            let uDef = board.nodeMap[def.u]!
            let vDef = board.nodeMap[def.v]!
            let start = nodePosition(uDef, board: board)
            let end = nodePosition(vDef, board: board)
            let es = state.edges[def.id] ?? EdgeState()
            let color = OwnershipPalette.color(for: es.owner)
            let thickness: Float = def.kind == .conduit ? 0.06 : 0.04
            let flux = Float(es.flux) / 100.0
            let severed: Float = es.severed ? 1.0 : 0.0
            let sealed: Float = es.sealed ? 1.0 : 0.0
            let conduit: Float = def.kind == .conduit ? 1.0 : 0.0
            return EdgeInstance(start: start, end: end, thickness: thickness,
                                color: color, flux: flux, severed: severed,
                                sealed: sealed, conduit: conduit,
                                phase: Float(min(uDef.plateau, vDef.plateau)) * 0.13)
        }
        // Persistent gold line work makes the static playfield read as a dense
        // holographic lattice even where no player owns a graph edge.
        result.append(contentsOf: holographicPanelGridInstances(board: board))
        return result
    }

    /// Build face instances from board + state. Each quad face = 2 triangles.
    public static func faceInstances(board: BoardDefinition, state: GameState) -> [FaceInstance] {
        var result: [FaceInstance] = []
        for face in board.faces {
            let fs = state.faces[face.id] ?? FaceState()
            guard let controller = fs.controller ?? fs.sealedBy else { continue }
            let color = OwnershipPalette.color(for: controller)
            let alpha: Float = fs.sealedBy != nil ? 0.25 : 0.12
            // Get the 4 corner nodes from the boundary edges.
            let corners = faceCorners(face, board: board)
            guard corners.count >= 4 else { continue }
            let p0 = nodePosition(board.nodeMap[corners[0]]!, board: board)
            let p1 = nodePosition(board.nodeMap[corners[1]]!, board: board)
            let p2 = nodePosition(board.nodeMap[corners[2]]!, board: board)
            let p3 = nodePosition(board.nodeMap[corners[3]]!, board: board)
            // Two triangles: (p0, p1, p2) and (p0, p2, p3)
            result.append(FaceInstance(v0: p0, v1: p1, v2: p2, color: color, alpha: alpha))
            result.append(FaceInstance(v0: p0, v1: p2, v2: p3, color: color, alpha: alpha))
        }
        return result
    }

    /// Extract the 4 corner node IDs from a face's boundary edges.
    static func faceCorners(_ face: FaceDef, board: BoardDefinition) -> [String] {
        var nodes: [String] = []
        for eid in face.boundary {
            guard let def = board.edgeMap[eid] else { continue }
            if !nodes.contains(def.u) { nodes.append(def.u) }
            if !nodes.contains(def.v) { nodes.append(def.v) }
        }
        return nodes
    }

    /// A low-opacity rectilinear grid for each projected plateau panel.
    private static func holographicPanelGridInstances(board: BoardDefinition) -> [EdgeInstance] {
        let color = SIMD4<Float>(1.0, 0.78, 0.26, 0.28)
        var instances: [EdgeInstance] = []
        for plateau in board.plateaus {
            let nodes = board.nodes.filter { $0.plateau == plateau.index }
            guard let minX = nodes.map(\.x).min(), let maxX = nodes.map(\.x).max(),
                  let minY = nodes.map(\.y).min(), let maxY = nodes.map(\.y).max() else { continue }
            for y in minY...maxY {
                guard let first = nodes.first(where: { $0.x == minX && $0.y == y }),
                      let last = nodes.first(where: { $0.x == maxX && $0.y == y }) else { continue }
                instances.append(EdgeInstance(start: nodePosition(first, board: board),
                                              end: nodePosition(last, board: board),
                                              thickness: 0.012, color: color, flux: 0.18,
                                              phase: Float(plateau.index) * 0.18))
            }
            for x in minX...maxX {
                guard let first = nodes.first(where: { $0.x == x && $0.y == minY }),
                      let last = nodes.first(where: { $0.x == x && $0.y == maxY }) else { continue }
                instances.append(EdgeInstance(start: nodePosition(first, board: board),
                                              end: nodePosition(last, board: board),
                                              thickness: 0.012, color: color, flux: 0.18,
                                              phase: Float(plateau.index) * 0.18 + 0.5))
            }
        }
        return instances
    }

    // MARK: - Icosahedron geometry (low-poly sphere for nodes)

    /// 12 vertices of a unit icosahedron.
    public static let icoVertices: [SIMD3<Float>] = {
        let t: Float = (1.0 + sqrt(5.0)) / 2.0
        let s: Float = 1.0 / sqrt(t * t + 1.0)
        let a = t * s
        let b = s
        return [
            [-b,  a,  0], [ b,  a,  0], [-b, -a,  0], [ b, -a,  0],
            [ 0, -b,  a], [ 0,  b,  a], [ 0, -b, -a], [ 0,  b, -a],
            [ a,  0, -b], [ a,  0,  b], [-a,  0, -b], [-a,  0,  b]
        ]
    }()

    /// Normals for the icosahedron (same as vertices since it's centered at origin).
    public static let icoNormals: [SIMD3<Float>] = icoVertices.map { normalize($0) }

    /// Quad vertices for edge rendering: (t, offset) pairs.
    /// 4 vertices forming a camera-facing quad: (0,-1), (0,1), (1,-1), (1,1)
    public static let edgeQuadVerts: [SIMD2<Float>] = [
        SIMD2<Float>(0, -1), SIMD2<Float>(0, 1),
        SIMD2<Float>(1, -1), SIMD2<Float>(1, 1)
    ]

    /// Edge index buffer for the quad (two triangles).
    public static let edgeIndices: [UInt16] = [0, 1, 2, 2, 1, 3]

    /// Board center for camera default target.
    public static func boardCenter(_ board: BoardDefinition) -> SIMD3<Float> {
        guard !board.nodes.isEmpty else { return SIMD3<Float>(0, 0, 0) }
        let positions = board.nodes.map { nodePosition($0, board: board) }
        return positions.reduce(SIMD3<Float>(repeating: 0), +) / Float(positions.count)
    }

    /// Compact framing volume for the gameplay panels. Presentation-only
    /// sensor trails intentionally do not widen this box.
    public static func boardExtents(_ board: BoardDefinition) -> SIMD3<Float> {
        guard let first = board.nodes.first else { return SIMD3<Float>(3, 3, 3) }
        var lower = nodePosition(first, board: board)
        var upper = lower
        for node in board.nodes.dropFirst() {
            let position = nodePosition(node, board: board)
            lower = simd_min(lower, position)
            upper = simd_max(upper, position)
        }
        // Node discs and holographic grids extend a little beyond vertices.
        return simd_max((upper - lower) * 0.5 + SIMD3<Float>(repeating: 0.8), SIMD3<Float>(repeating: 2.0))
    }
}
