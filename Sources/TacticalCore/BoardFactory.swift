import Foundation

/// Programmatic board builders + topology validation. The JSON files in
/// `Boards/` are the canonical data source for the data-driven pipeline
/// (loaded by TacticalTools in a later slice); the engine uses these builders
/// directly so the pure core has no file-IO dependency.
public enum BoardFactory {

    /// Triad training board: 3 plateaus × 4×4 = 48 nodes, 72 intra edges,
    /// 12 conduits, 27 faces.
    public static func triad() -> BoardDefinition {
        let size = 4
        var nodes: [NodeDef] = []
        var edges: [EdgeDef] = []
        var faces: [FaceDef] = []
        var plateaus: [PlateauDef] = []

        let plateauNames = ["Alpha", "Beta", "Gamma"]
        let conduitCoords: [(Int, Int)] = [(0,0),(0,3),(3,0),(3,3),(1,1),(2,2)]

        for p in 0..<3 {
            var pNodeIds: [String] = []
            var pFaceIds: [String] = []
            for y in 0..<size {
                for x in 0..<size {
                    let id = nid(p, x, y)
                    let isConduit = conduitCoords.contains(where: { $0.0 == x && $0.1 == y })
                    nodes.append(NodeDef(id: id, plateau: p, x: x, y: y,
                                         kind: isConduit ? .conduit : .standard))
                    pNodeIds.append(id)
                }
            }
            // Intra edges: right + down
            for y in 0..<size {
                for x in 0..<size {
                    if x + 1 < size {
                        edges.append(EdgeDef(u: nid(p, x, y), v: nid(p, x+1, y), kind: .intra))
                    }
                    if y + 1 < size {
                        edges.append(EdgeDef(u: nid(p, x, y), v: nid(p, x, y+1), kind: .intra))
                    }
                }
            }
            // Faces: 3x3 unit squares
            for y in 0..<(size-1) {
                for x in 0..<(size-1) {
                    let fid = "F_p\(p)_x\(x)_y\(y)"
                    let top = eid(nid(p,x,y), nid(p,x+1,y))
                    let bottom = eid(nid(p,x,y+1), nid(p,x+1,y+1))
                    let left = eid(nid(p,x,y), nid(p,x,y+1))
                    let right = eid(nid(p,x+1,y), nid(p,x+1,y+1))
                    // Ordered cycle: top, right, bottom, left (reversed for orientation)
                    faces.append(FaceDef(id: fid, boundary: [top, right, bottom, left],
                                         plateau: p, area: 1))
                    pFaceIds.append(fid)
                }
            }
            plateaus.append(PlateauDef(index: p, name: plateauNames[p],
                                       nodeIds: pNodeIds, faceIds: pFaceIds))
        }

        // Conduits: Alpha<->Beta and Beta<->Gamma at the 6 conduit coords.
        for (x, y) in conduitCoords {
            let cap = ((x == 1 || x == 2) && (y == 1 || y == 2)) ? 2 : 1  // center conduits wider
            edges.append(EdgeDef(u: nid(0,x,y), v: nid(1,x,y), kind: .conduit, capacity: cap))
            edges.append(EdgeDef(u: nid(1,x,y), v: nid(2,x,y), kind: .conduit, capacity: cap))
        }

        let anchors = AnchorSpec(
            player1: [nid(0,0,0), nid(2,0,3)],
            player2: [nid(0,3,3), nid(2,3,0)]
        )
        // Mark anchor nodes
        nodes = nodes.map { n in
            if anchors.player1.contains(n.id) || anchors.player2.contains(n.id) {
                return NodeDef(id: n.id, plateau: n.plateau, x: n.x, y: n.y, kind: .anchor)
            }
            return n
        }

        return BoardDefinition(id: "triad", version: 1, plateaus: plateaus,
                               nodes: nodes, edges: edges, faces: faces, anchors: anchors)
    }

    /// Grandmaster board: 6 plateaus, irregular, data-authored geometry per
    /// rulebook §3.2. Not all 4x4; some plateaus have 5- or 6-node faces,
    /// missing nodes, diagonal intra edges, and bridging conduits. Includes
    /// cross-plateau sector faces (Cross) whose boundaries traverse conduits.
    /// All face boundaries are verified as simple cycles by BoardValidator.
    public static func grandmaster() -> BoardDefinition {
        var nodes: [NodeDef] = []
        var edges: [EdgeDef] = []
        var faces: [FaceDef] = []
        var plateaus: [PlateauDef] = []

        // A grid coordinate. Swift tuples are not Hashable, so a value type is
        // used for the missing-node set and the face-cycle vertex lists.
        struct P: Hashable, Sendable {
            let x: Int; let y: Int
            init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
        }
        struct FaceSpec {
            let suffix: String
            let cycle: [P]
            let area: Int
            init(_ suffix: String, _ cycle: [P], _ area: Int) {
                self.suffix = suffix; self.cycle = cycle; self.area = area
            }
        }
        struct PlateauSpec {
            let index: Int
            let name: String
            let width: Int
            let height: Int
            let missing: Set<P>
            let diagonals: [(P, P)]
            let faceSpecs: [FaceSpec]
        }

        // p0 "Apex" — 4x4 minus (2,1). 15 nodes. 5 unit faces + 1 eight-node
        // face around the gap. Demonstrates missing-node irregularity.
        let p0 = PlateauSpec(index: 0, name: "Apex", width: 4, height: 4,
            missing: [P(2,1)],
            diagonals: [],
            faceSpecs: [
                FaceSpec("u00", [P(0,0),P(1,0),P(1,1),P(0,1)], 2),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u02", [P(0,2),P(1,2),P(1,3),P(0,3)], 2),
                FaceSpec("u12", [P(1,2),P(2,2),P(2,3),P(1,3)], 2),
                FaceSpec("u22", [P(2,2),P(3,2),P(3,3),P(2,3)], 2),
                FaceSpec("gap8", [P(1,0),P(2,0),P(3,0),P(3,1),P(3,2),P(2,2),P(1,2),P(1,1)], 4)
            ])
        // p1 "Helix" — 3x3 with diagonal (0,0)-(1,1). 9 nodes.
        // 1 five-node face + 2 unit faces. Demonstrates 5-node face.
        let p1 = PlateauSpec(index: 1, name: "Helix", width: 3, height: 3,
            missing: [],
            diagonals: [(P(0,0), P(1,1))],
            faceSpecs: [
                FaceSpec("penta", [P(0,0),P(1,0),P(2,0),P(2,1),P(1,1)], 3),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u11", [P(1,1),P(2,1),P(2,2),P(1,2)], 2)
            ])
        // p2 "Drift" — 4x3. 12 nodes. 2 six-node faces + 2 unit faces.
        // Demonstrates 6-node faces.
        let p2 = PlateauSpec(index: 2, name: "Drift", width: 4, height: 3,
            missing: [],
            diagonals: [],
            faceSpecs: [
                FaceSpec("hexL", [P(0,0),P(1,0),P(2,0),P(2,1),P(1,1),P(0,1)], 3),
                FaceSpec("hexR", [P(2,0),P(3,0),P(3,1),P(3,2),P(2,2),P(2,1)], 3),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u11", [P(1,1),P(2,1),P(2,2),P(1,2)], 2)
            ])
        // p3 "Quill" — 3x3 regular. 9 nodes. 4 unit faces. Stable center.
        let p3 = PlateauSpec(index: 3, name: "Quill", width: 3, height: 3,
            missing: [],
            diagonals: [],
            faceSpecs: [
                FaceSpec("u00", [P(0,0),P(1,0),P(1,1),P(0,1)], 2),
                FaceSpec("u10", [P(1,0),P(2,0),P(2,1),P(1,1)], 2),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u11", [P(1,1),P(2,1),P(2,2),P(1,2)], 2)
            ])
        // p4 "Mantle" — 4x4 with diagonal (1,1)-(2,2). 16 nodes.
        // 1 five-node face + 7 unit faces. Demonstrates 5-node face.
        let p4 = PlateauSpec(index: 4, name: "Mantle", width: 4, height: 4,
            missing: [],
            diagonals: [(P(1,1), P(2,2))],
            faceSpecs: [
                FaceSpec("penta", [P(1,0),P(2,0),P(2,1),P(2,2),P(1,1)], 3),
                FaceSpec("u00", [P(0,0),P(1,0),P(1,1),P(0,1)], 2),
                FaceSpec("u20", [P(2,0),P(3,0),P(3,1),P(2,1)], 2),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u21", [P(2,1),P(3,1),P(3,2),P(2,2)], 2),
                FaceSpec("u02", [P(0,2),P(1,2),P(1,3),P(0,3)], 2),
                FaceSpec("u12", [P(1,2),P(2,2),P(2,3),P(1,3)], 2),
                FaceSpec("u22", [P(2,2),P(3,2),P(3,3),P(2,3)], 2)
            ])
        // p5 "Cinder" — 3x3. 9 nodes. 1 six-node face + 2 unit faces.
        let p5 = PlateauSpec(index: 5, name: "Cinder", width: 3, height: 3,
            missing: [],
            diagonals: [],
            faceSpecs: [
                FaceSpec("hexT", [P(0,0),P(1,0),P(2,0),P(2,1),P(1,1),P(0,1)], 3),
                FaceSpec("u01", [P(0,1),P(1,1),P(1,2),P(0,2)], 2),
                FaceSpec("u11", [P(1,1),P(2,1),P(2,2),P(1,2)], 2)
            ])
        let specs: [PlateauSpec] = [p0, p1, p2, p3, p4, p5]

        for spec in specs {
            let p = spec.index
            var pNodeIds: [String] = []
            var pFaceIds: [String] = []
            // Nodes (skip missing coords).
            for y in 0..<spec.height {
                for x in 0..<spec.width {
                    if spec.missing.contains(P(x, y)) { continue }
                    let id = nid(p, x, y)
                    nodes.append(NodeDef(id: id, plateau: p, x: x, y: y))
                    pNodeIds.append(id)
                }
            }
            // Intra edges: right + down (skip if either endpoint is missing).
            for y in 0..<spec.height {
                for x in 0..<spec.width {
                    if spec.missing.contains(P(x, y)) { continue }
                    if x + 1 < spec.width && !spec.missing.contains(P(x+1, y)) {
                        edges.append(EdgeDef(u: nid(p,x,y), v: nid(p,x+1,y), kind: .intra))
                    }
                    if y + 1 < spec.height && !spec.missing.contains(P(x, y+1)) {
                        edges.append(EdgeDef(u: nid(p,x,y), v: nid(p,x,y+1), kind: .intra))
                    }
                }
            }
            // Diagonal intra edges (enable 5-node faces).
            for (a, b) in spec.diagonals {
                edges.append(EdgeDef(u: nid(p,a.x,a.y), v: nid(p,b.x,b.y), kind: .intra))
            }
            // Faces from specs.
            for fs in spec.faceSpecs {
                let fid = "F_p\(p)_\(fs.suffix)"
                let nodeCycle = fs.cycle.map { nid(p, $0.x, $0.y) }
                let boundary = faceBoundary(nodeCycle)
                faces.append(FaceDef(id: fid, boundary: boundary, plateau: p, area: fs.area))
                pFaceIds.append(fid)
            }
            plateaus.append(PlateauDef(index: p, name: spec.name,
                                       nodeIds: pNodeIds, faceIds: pFaceIds))
        }

        // Conduits: interlinked fronts with capacity in {1,2,3}.
        // Chain: 0<->1<->2<->3<->4<->5. Cross links: 0<->3, 1<->4, 2<->5.
        // Plus two extra conduits (second 0<->3, second 1<->4) to close the
        // cross-plateau sector face cycles.
        let conduitPairs: [(Int,Int,Int,Int,Int,Int,Int)] = [
            (0,3,3, 1,0,0, 2),   // 0<->1
            (1,2,2, 2,0,0, 1),   // 1<->2
            (2,3,2, 3,0,0, 3),   // 2<->3
            (3,2,2, 4,0,0, 2),   // 3<->4
            (4,3,3, 5,0,0, 1),   // 4<->5
            (0,3,0, 3,0,2, 3),   // 0<->3 cross link
            (1,0,2, 4,2,0, 2),   // 1<->4 cross link
            (2,0,2, 5,2,0, 1),   // 2<->5 cross link
            (0,2,0, 3,0,1, 2),   // 0<->3 second (for cross face CF-A)
            (1,1,2, 4,2,1, 1)    // 1<->4 second (for cross face CF-B)
        ]
        for (pa,xa,ya, pb,xb,yb, cap) in conduitPairs {
            edges.append(EdgeDef(u: nid(pa,xa,ya), v: nid(pb,xb,yb), kind: .conduit, capacity: cap))
        }

        // Cross-plateau sector faces (Cross, plateau = -1). Boundaries traverse
        // conduits + intra edges, forming simple cycles verified by the validator.
        // CF-A: conduit 0(3,0)->3(0,2), intra 3(0,2)->3(0,1), conduit 3(0,1)->0(2,0),
        //        intra 0(2,0)->0(3,0).
        let cfA = faceBoundary([nid(0,3,0), nid(3,0,2), nid(3,0,1), nid(0,2,0)])
        faces.append(FaceDef(id: "F_CF_A", boundary: cfA, plateau: -1, area: 5, kind: .cross))
        // CF-B: conduit 1(0,2)->4(2,0), intra 4(2,0)->4(2,1), conduit 4(2,1)->1(1,2),
        //        intra 1(1,2)->1(0,2).
        let cfB = faceBoundary([nid(1,0,2), nid(4,2,0), nid(4,2,1), nid(1,1,2)])
        faces.append(FaceDef(id: "F_CF_B", boundary: cfB, plateau: -1, area: 5, kind: .cross))
        // Attach cross faces to no plateau (plateau = -1); they are not listed in
        // any PlateauDef.faceIds. The engine looks up faces by id from the board's
        // flat face list, so cross faces are reachable without a plateau owner.

        let anchors = AnchorSpec(
            player1: [nid(0,0,0), nid(5,2,2)],
            player2: [nid(0,3,3), nid(5,0,0)]
        )
        nodes = nodes.map { n in
            if anchors.player1.contains(n.id) || anchors.player2.contains(n.id) {
                return NodeDef(id: n.id, plateau: n.plateau, x: n.x, y: n.y, kind: .anchor)
            }
            return n
        }

        return BoardDefinition(id: "grandmaster", version: 2, plateaus: plateaus,
                               nodes: nodes, edges: edges, faces: faces, anchors: anchors)
    }

    // MARK: helpers
    static func nid(_ p: Int, _ x: Int, _ y: Int) -> String { "p\(p)x\(x)y\(y)" }
    static func eid(_ a: String, _ b: String) -> String {
        let s = [a, b].sorted(); return s[0] + "--" + s[1]
    }
    /// Convert an ordered node cycle (node[i] connects to node[i+1], last wraps
    /// to first) into the ordered list of canonical edge ids forming the face
    /// boundary. Every edge must already exist in the edge set for the validator
    /// to accept the face.
    static func faceBoundary(_ cycle: [String]) -> [String] {
        guard cycle.count >= 3 else { return [] }
        var b: [String] = []
        for i in 0..<cycle.count {
            b.append(eid(cycle[i], cycle[(i + 1) % cycle.count]))
        }
        return b
    }
}

/// Topology validation. Fails the build/load if the board is incoherent.
public enum BoardValidator {
    public enum ValidationError: Error, Sendable {
        case duplicateNodeId(String)
        case duplicateEdgeId(String)
        case edgeReferencesMissingNode(String)
        case faceReferencesMissingEdge(String)
        case faceBoundaryNotSimpleCycle(String)
        case anchorNotFound(String)
        case anchorNotOnNodeList(String)
        case emptyBoard
    }

    public static func validate(_ b: BoardDefinition) throws {
        guard !b.nodes.isEmpty else { throw ValidationError.emptyBoard }
        var seenNodes = Set<String>()
        for n in b.nodes {
            if !seenNodes.insert(n.id).inserted { throw ValidationError.duplicateNodeId(n.id) }
        }
        var seenEdges = Set<String>()
        let nodeSet = seenNodes
        for e in b.edges {
            if !seenEdges.insert(e.id).inserted { throw ValidationError.duplicateEdgeId(e.id) }
            if !nodeSet.contains(e.u) || !nodeSet.contains(e.v) {
                throw ValidationError.edgeReferencesMissingNode(e.id)
            }
        }
        let edgeSet = seenEdges
        for f in b.faces {
            for eid in f.boundary {
                if !edgeSet.contains(eid) {
                    throw ValidationError.faceReferencesMissingEdge("\(f.id)->\(eid)")
                }
            }
            // Simple cycle check: each edge in the boundary must form a closed walk.
            if !isSimpleCycle(f.boundary, edgeMap: b.edgeMap) {
                throw ValidationError.faceBoundaryNotSimpleCycle(f.id)
            }
        }
        for a in b.anchors.player1 + b.anchors.player2 {
            if !nodeSet.contains(a) { throw ValidationError.anchorNotFound(a) }
        }
    }

    /// A boundary is a simple cycle iff consecutive edges share exactly one node,
    /// the last and first share one node, and no node is visited twice (except
    /// the start/end).
    static func isSimpleCycle(_ boundary: [String], edgeMap: [String: EdgeDef]) -> Bool {
        guard boundary.count >= 3 else { return false }
        var nodeSequence: [String] = []
        let first = edgeMap[boundary[0]]!
        var prev = first.u   // walk orientation: u -> v
        nodeSequence.append(first.u)
        nodeSequence.append(first.v)
        prev = first.v
        for i in 1..<boundary.count {
            let e = edgeMap[boundary[i]]!
            let next = (e.u == prev) ? e.v : (e.v == prev ? e.u : nil)
            guard let n = next else { return false }
            nodeSequence.append(n)
            prev = n
        }
        // Close: last node must equal first.
        guard nodeSequence.last == nodeSequence.first else { return false }
        // Simple: interior nodes unique.
        let interior = nodeSequence.dropLast()
        return Set(interior).count == interior.count
    }
}
