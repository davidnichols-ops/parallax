import XCTest
@testable import TacticalCore

final class BoardTests: XCTestCase {
    func testTriadBoardShape() throws {
        let b = BoardFactory.triad()
        try BoardValidator.validate(b)
        XCTAssertEqual(b.nodes.count, 48, "Triad has 48 nodes")
        XCTAssertEqual(b.plateaus.count, 3)
        // 72 intra + 12 conduit = 84 edges.
        let intra = b.edges.filter { $0.kind == .intra }.count
        let conduit = b.edges.filter { $0.kind == .conduit }.count
        XCTAssertEqual(intra, 72, "Triad has 72 intra edges")
        XCTAssertEqual(conduit, 12, "Triad has 12 conduits")
        XCTAssertEqual(b.faces.count, 27, "Triad has 27 faces (3x3 per plateau)")
        XCTAssertEqual(b.anchors.player1.count, 2)
        XCTAssertEqual(b.anchors.player2.count, 2)
    }

    func testGrandmasterBoardValidates() throws {
        let b = BoardFactory.grandmaster()
        try BoardValidator.validate(b)
        XCTAssertEqual(b.plateaus.count, 6, "Grandmaster has 6 plateaus")
        XCTAssertEqual(b.version, 2, "Authored Grandmaster is version 2")
        // 70 nodes: 15+9+12+9+16+9.
        XCTAssertEqual(b.nodes.count, 70, "Grandmaster has 70 nodes")
        // 10 conduits with capacity in {1,2,3}.
        let conduits = b.edges.filter { $0.kind == .conduit }
        XCTAssertEqual(conduits.count, 10, "Grandmaster has 10 conduits")
        for c in conduits {
            XCTAssertTrue(c.capacity >= 1 && c.capacity <= 3,
                          "Conduit \(c.id) capacity \(c.capacity) not in {1,2,3}")
        }
        // 2 cross-plateau sector faces.
        let crossFaces = b.faces.filter { $0.kind == .cross }
        XCTAssertEqual(crossFaces.count, 2, "Grandmaster has 2 cross faces")
        for f in crossFaces {
            XCTAssertEqual(f.plateau, -1, "Cross face \(f.id) plateau must be -1")
        }
        // Irregular faces: at least one 5-node and one 6-node face.
        let faceNodeCounts = b.faces.map { face -> Int in
            var s = Set<String>()
            for eid in face.boundary {
                guard let e = b.edgeMap[eid] else { return 0 }
                s.insert(e.u); s.insert(e.v)
            }
            return s.count
        }
        XCTAssertTrue(faceNodeCounts.contains(5), "Missing a 5-node face")
        XCTAssertTrue(faceNodeCounts.contains(6), "Missing a 6-node face")
        // Missing node: p0x2y1 must NOT exist (Apex 4x4 minus (2,1)).
        XCTAssertNil(b.nodeMap["p0x2y1"], "Apex missing node p0x2y1 should not exist")
        XCTAssertEqual(b.plateaus[0].nodeIds.count, 15, "Apex has 15 nodes (4x4 minus 1)")
        // Anchors unchanged.
        XCTAssertEqual(b.anchors.player1.count, 2)
        XCTAssertEqual(b.anchors.player2.count, 2)
    }

    func testAnchorsAreLockedAndOwned() throws {
        let b = BoardFactory.triad()
        let s = GameState(board: b, matchSeed: 1)
        for a in b.anchors.player1 {
            XCTAssertEqual(s.nodes[a]?.owner, .player1)
            XCTAssertEqual(s.nodes[a]?.influence, 100)
            XCTAssertTrue(s.nodes[a]?.locked == true)
        }
        for a in b.anchors.player2 {
            XCTAssertEqual(s.nodes[a]?.owner, .player2)
            XCTAssertTrue(s.nodes[a]?.locked == true)
        }
    }

    func testEdgeIdsAreCanonicalSorted() {
        let e = EdgeDef(u: "b", v: "a", kind: .intra)
        XCTAssertEqual(e.id, "a--b")
        XCTAssertEqual(e.u, "a")
        XCTAssertEqual(e.v, "b")
    }
}
