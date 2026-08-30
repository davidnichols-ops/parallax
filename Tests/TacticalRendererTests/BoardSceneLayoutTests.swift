import XCTest
import SceneKit
import Metal
import AppKit
@testable import TacticalRenderer
import TacticalCore

/// Headless geometry/framing tests for the new SceneKit board layout.
///
/// These verify the pure layout math and the live BoardHostingView scene graph
/// without simulating real user clicks. A SceneKit snapshot is attempted when a
/// Metal device is available; otherwise it is skipped (never faked).
@MainActor
final class BoardSceneLayoutTests: XCTestCase {

    // MARK: - Pure layout math

    func testTriadLayoutPanelDimensions() {
        let board = BoardFactory.triad()
        let layout = BoardSceneLayout.compute(for: board)
        // Triad: 4x4 nodes per plateau, gridUnit 1.5, margin 0.9.
        // panelWidth/Height = (maxX+1)*1.5 + 0.9*2 = 4*1.5 + 1.8 = 7.8
        XCTAssertEqual(layout.panelWidth, 7.8, accuracy: 0.001)
        XCTAssertEqual(layout.panelHeight, 7.8, accuracy: 0.001)
        // 3 plateaus => 2 inter-plateau gaps * 2.4 = 4.8
        XCTAssertEqual(layout.depthSpan, 4.8, accuracy: 0.001)
    }

    func testPlateausAreSeparatedAlongDepth() {
        let board = BoardFactory.triad()
        let layout = BoardSceneLayout.compute(for: board)
        let alpha = layout.nodePosition["p0x0y0"]!
        let beta = layout.nodePosition["p1x0y0"]!
        let gamma = layout.nodePosition["p2x0y0"]!
        // Same column => same X, same Y; different Z (depth) per plateau.
        XCTAssertEqual(alpha.x, beta.x, accuracy: 0.001)
        XCTAssertEqual(alpha.y, beta.y, accuracy: 0.001)
        XCTAssertEqual(alpha.x, gamma.x, accuracy: 0.001)
        XCTAssertNotEqual(alpha.z, beta.z)
        XCTAssertNotEqual(beta.z, gamma.z)
        // Centered stack: alpha and gamma are symmetric around z=0.
        XCTAssertEqual(alpha.z, -gamma.z, accuracy: 0.001)
        XCTAssertEqual(beta.z, 0, accuracy: 0.001)
    }

    func testNodePositionsAreCentered() {
        let board = BoardFactory.triad()
        let layout = BoardSceneLayout.compute(for: board)
        // The board is centered around the origin in X/Y for each plateau.
        let xs = layout.nodePosition.values.map(\.x)
        let ys = layout.nodePosition.values.map(\.y)
        let xRange = (xs.max() ?? 0) - (xs.min() ?? 0)
        let yRange = (ys.max() ?? 0) - (ys.min() ?? 0)
        // 4 nodes spanning 0..3 => centered range = 3 * gridUnit = 4.5
        XCTAssertEqual(xRange, 4.5, accuracy: 0.001)
        XCTAssertEqual(yRange, 4.5, accuracy: 0.001)
    }

    // MARK: - Camera framing

    func testFramingDistanceScalesWithBoardSize() {
        let triad = BoardSceneLayout.compute(for: BoardFactory.triad())
        let grand = BoardSceneLayout.compute(for: BoardFactory.grandmaster())
        let distTriad = triad.framingDistance(aspect: 1.0, fovDegrees: 48)
        let distGrand = grand.framingDistance(aspect: 1.0, fovDegrees: 48)
        // Larger board => camera farther away so the board fills the frame.
        XCTAssertGreaterThan(distGrand, distTriad)
        XCTAssertGreaterThanOrEqual(distGrand, 14)
        XCTAssertGreaterThanOrEqual(distTriad, 14)
    }

    func testFramingDistanceRespectsAspect() {
        let layout = BoardSceneLayout.compute(for: BoardFactory.triad())
        let portrait = layout.framingDistance(aspect: 0.5, fovDegrees: 48)
        let landscape = layout.framingDistance(aspect: 2.0, fovDegrees: 48)
        // A narrow (portrait) viewport needs the camera farther away to fit
        // the board's width; a wide viewport can move closer.
        XCTAssertGreaterThan(portrait, landscape)
    }

    func testFramingDistanceIsFiniteAndPositive() {
        let layout = BoardSceneLayout.compute(for: BoardFactory.triad())
        for aspect in [Float(0.25), 0.5, 1.0, 2.0, 4.0] {
            let d = layout.framingDistance(aspect: aspect, fovDegrees: 48)
            XCTAssertTrue(d.isFinite)
            XCTAssertGreaterThan(d, 0)
        }
    }

    func testPerspectiveFramingFillsTheViewportWithoutClipping() {
        for board in [BoardFactory.triad(), BoardFactory.grandmaster()] {
            let layout = BoardSceneLayout.compute(for: board)
            var points = Array(layout.nodePosition.values)
            for x in [-layout.panelWidth * 0.65, layout.panelWidth * 0.65] {
                for y in [-layout.panelHeight * 0.5 - 1.2, layout.panelHeight * 0.5] {
                    for z in [-layout.depthSpan * 0.5, layout.depthSpan * 0.5 + 2] {
                        points.append(SIMD3<Float>(x, y, z))
                    }
                }
            }
            let direction = layout.cameraDirection
            let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), direction))
            let up = simd_cross(direction, right)
            let tangent = tan(Float(48) * .pi / 360)
            for aspect in [Float(0.5), 1, 2, 4] {
                let framing = layout.perspectiveFrame(points: points, aspect: aspect, fovDegrees: 48)
                var xs: [Float] = [], ys: [Float] = []
                for point in points {
                    let relative = point - framing.target
                    let depth = framing.distance - simd_dot(relative, direction)
                    XCTAssertGreaterThan(depth, 0)
                    xs.append(simd_dot(relative, right) / (depth * tangent * aspect))
                    ys.append(simd_dot(relative, up) / (depth * tangent))
                }
                XCTAssertLessThanOrEqual(xs.map(abs).max()!, 0.941)
                XCTAssertLessThanOrEqual(ys.map(abs).max()!, 0.941)
                let coverage = max(xs.max()! - xs.min()!, ys.max()! - ys.min()!)
                XCTAssertEqual(coverage, 1.88, accuracy: 0.002,
                               "One axis should fill 94% even with a deep, asymmetric projector")
            }
        }
    }

    // MARK: - Live scene graph (no window required)

    func testBoardHostingViewBuildsTokenForEachNode() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // Every board node should have a registered selectable token node.
        for node in board.nodes {
            let token = view.tokenNode(forNodeId: node.id)
            XCTAssertNotNil(token, "Missing token for node \(node.id)")
            XCTAssertEqual(token?.name, node.id)
        }
    }

    func testSelectionRingAppearsForSelectedNode() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        let target = board.nodes.first!.id
        view.configure(board: board, state: state, selectedNodeId: target)
        XCTAssertTrue(view.hasSelectionRing(), "No selection ring attached for \(target)")
    }

    func testSelectionRingRemovedWhenSelectionCleared() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        let target = board.nodes.first!.id
        view.configure(board: board, state: state, selectedNodeId: target)
        XCTAssertTrue(view.hasSelectionRing())
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertFalse(view.hasSelectionRing(), "Selection ring not removed when cleared")
    }

    func testRebuildProducesNonEmptyScene() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        guard let scene = view.sceneSnapshot() else {
            throw XCTSkip("SceneKit scene unavailable in headless test host")
        }
        // The scene must contain the board geometry, not just an empty root.
        XCTAssertGreaterThan(scene.rootNode.childNodes.count, 1)
    }

    func testReduceMotionDisablesContinuousRendering() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = true
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertFalse(view.rendersContinuouslyEnabled(),
                       "reduceMotion should disable continuous rendering")
    }

    func testHighContrastRebuildsScene() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.highContrast = false
        view.configure(board: board, state: state, selectedNodeId: nil)
        let tokenBefore = view.tokenNode(forNodeId: board.nodes.first!.id)
        view.highContrast = true
        view.configure(board: board, state: state, selectedNodeId: nil)
        let tokenAfter = view.tokenNode(forNodeId: board.nodes.first!.id)
        XCTAssertNotNil(tokenBefore)
        XCTAssertNotNil(tokenAfter)
        // Toggling highContrast rebuilds the scene; tokens are re-created.
        XCTAssertFalse(tokenBefore === tokenAfter)
    }

    // MARK: - Snapshot (real render, only when GPU available)

    func testCameraBelongsToTheRenderedScene() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let board = BoardFactory.triad()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1), selectedNodeId: nil)
        let scene = try XCTUnwrap(view.sceneSnapshot())
        let camera = try XCTUnwrap(scene.rootNode.childNode(withName: "board-camera", recursively: false))
        XCTAssertNotNil(camera.camera)
    }

    func testHollowRingCentersAreSelectable() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1200, height: 600))
        let board = BoardFactory.triad()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1), selectedNodeId: nil)
        view.layoutSubtreeIfNeeded()
        for node in board.nodes where node.plateau == 0 {
            let point = try XCTUnwrap(view.projectedPoint(forNodeID: node.id))
            XCTAssertEqual(view.pickNodeID(at: point), node.id, "Ring center must select \(node.id)")
        }
    }

    func testTokenCoresRemainAtTheirRingCenters() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        let board = BoardFactory.triad()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1), selectedNodeId: nil)
        for node in board.nodes {
            let ring = try XCTUnwrap(view.tokenNode(forNodeId: node.id))
            let core = try XCTUnwrap(ring.childNode(withName: "core", recursively: false))
            let offset = core.simdWorldPosition - ring.simdWorldPosition
            XCTAssertLessThan(simd_length(offset), 0.08)
        }
    }

    func testForgingUpdatesTheRenderedLink() throws {
        let board = BoardFactory.triad()
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1000, height: 600))
        var engine = Engine(board: board, matchSeed: 1)
        view.configure(board: board, state: engine.state, selectedNodeId: nil)
        let scene = try XCTUnwrap(view.sceneSnapshot())
        let link = try XCTUnwrap(scene.rootNode.childNode(withName: "edge:p0x0y0--p0x1y0", recursively: false))
        let before = try XCTUnwrap(link.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        engine.submitTick([.forge(.player1, "p0x0y0--p0x1y0"), .yield_(.player2)])
        view.configure(board: board, state: engine.state, selectedNodeId: nil)
        let after = try XCTUnwrap(link.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        XCTAssertNotEqual(before, after)
    }

    func testSceneSnapshotProducesNonBlankImage() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal device unavailable — cannot render snapshot")
        }
        _ = device
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: board.nodes.first?.id)
        view.layoutSubtreeIfNeeded()
        guard let image = view.renderSnapshot() else {
            throw XCTSkip("SceneKit snapshot unavailable in headless test host")
        }
        // The snapshot must have non-zero dimensions and not be entirely empty.
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
        let data = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
        var litPixels = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                if let color, max(color.redComponent, color.greenComponent, color.blueComponent) > 0.2 {
                    litPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(litPixels, 40, "A nonzero-sized black frame is still a rendering failure")
    }

    // MARK: - Territory face rendering (state-dependent)

    func testNoTerritoryFacesAtNeutralStart() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // No face is controlled at the start => no territory nodes.
        for face in board.faces {
            XCTAssertNil(view.territoryFaceNode(forFaceId: face.id),
                         "Face \(face.id) should not render at neutral start")
        }
    }

    func testTerritoryFaceAppearsWhenControlled() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.controller = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        let node = view.territoryFaceNode(forFaceId: faceId)
        XCTAssertNotNil(node, "Controlled face should render a territory node")
        XCTAssertEqual(node?.name, "territory:\(faceId)")
    }

    func testTerritoryFaceRemovedWhenControlLost() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.controller = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertNotNil(view.territoryFaceNode(forFaceId: faceId))
        // Clear control and reconfigure.
        state.faces[faceId]?.controller = nil
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertNil(view.territoryFaceNode(forFaceId: faceId),
                     "Territory node should be removed when control is lost")
    }

    func testTerritoryFaceColorChangesWithController() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.controller = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        let node = try XCTUnwrap(view.territoryFaceNode(forFaceId: faceId))
        let colorP1 = try XCTUnwrap(node.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        // Switch controller to player2 via updateDynamicContent path.
        state.faces[faceId]?.controller = .player2
        view.configure(board: board, state: state, selectedNodeId: nil)
        let colorP2 = try XCTUnwrap(node.geometry?.firstMaterial?.diffuse.contents as? NSColor)
        XCTAssertNotEqual(colorP1, colorP2, "Territory color should change with controller")
    }

    func testSealedTerritoryFaceHigherAlpha() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.sealedBy = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        let node = try XCTUnwrap(view.territoryFaceNode(forFaceId: faceId))
        let alpha = node.geometry?.firstMaterial?.transparency ?? 0
        XCTAssertEqual(alpha, 0.25, accuracy: 0.001,
                       "Sealed face should have 0.25 alpha")
    }

    func testGrandmasterIrregularFacesRenderWhenControlled() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.grandmaster()
        var state = GameState(board: board, matchSeed: 1)
        // Control the 8-node gap face on Apex (irregular).
        state.faces["F_p0_gap8"]?.controller = .player1
        // Control a 5-node face on Helix.
        state.faces["F_p1_penta"]?.controller = .player2
        // Control a 6-node face on Drift.
        state.faces["F_p2_hexL"]?.controller = .player1
        // Control a cross-plateau sector face.
        state.faces["F_CF_A"]?.controller = .player2
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertNotNil(view.territoryFaceNode(forFaceId: "F_p0_gap8"),
                        "8-node gap face should render")
        XCTAssertNotNil(view.territoryFaceNode(forFaceId: "F_p1_penta"),
                        "5-node penta face should render")
        XCTAssertNotNil(view.territoryFaceNode(forFaceId: "F_p2_hexL"),
                        "6-node hex face should render")
        XCTAssertNotNil(view.territoryFaceNode(forFaceId: "F_CF_A"),
                        "Cross-plateau sector face should render")
    }

    // MARK: - Segment 4: projection bloom, scanline, grid energy, depth, feedback

    /// Owned tokens (anchors are owned at start) carry an additive bloom halo;
    /// neutral tokens do not, keeping the board as sparse projected light.
    func testOwnedTokensCarryBloomHalo() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // Anchors are owned at start => bloom present.
        for anchorId in board.anchors.player1 + board.anchors.player2 {
            XCTAssertNotNil(view.tokenBloomNode(forNodeId: anchorId),
                            "Owned anchor \(anchorId) should carry a bloom halo")
        }
    }

    func testNeutralTokensHaveNoBloom() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // A non-anchor node is neutral at start => no bloom.
        let neutral = board.nodes.first { $0.kind == .standard }!.id
        XCTAssertNil(view.tokenBloomNode(forNodeId: neutral),
                     "Neutral token \(neutral) should not bloom")
    }

    /// Non-severed edges carry an additive bloom halo child.
    func testEdgesCarryBloomHalo() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // All edges start non-severed => all should bloom.
        for edge in board.edges {
            XCTAssertNotNil(view.edgeBloomNode(forEdgeId: edge.id),
                            "Non-severed edge \(edge.id) should carry a bloom halo")
        }
    }

    /// Sealed territory faces carry a scanline shimmer child; controlled-but-
    /// unsealed faces do not.
    func testSealedTerritoryFaceHasScanline() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let sealedId = board.faces.first!.id
        state.faces[sealedId]?.sealedBy = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertNotNil(view.territoryScanlineNode(forFaceId: sealedId),
                        "Sealed face should carry a scanline shimmer")
    }

    func testControlledOnlyFaceHasNoScanline() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.controller = .player1  // controlled, not sealed
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertNil(view.territoryScanlineNode(forFaceId: faceId),
                     "Controlled-only face should not have a scanline")
    }

    /// Under reduceMotion the scanline node is present (testable scene graph)
    /// but hidden and static.
    func testScanlineHiddenUnderReduceMotion() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = true
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.sealedBy = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        let scanline = view.territoryScanlineNode(forFaceId: faceId)
        XCTAssertNotNil(scanline, "Scanline node should exist for testability")
        XCTAssertTrue(scanline?.isHidden ?? false,
                      "Scanline should be hidden under reduceMotion")
        XCTAssertTrue(scanline?.actionKeys.isEmpty ?? true,
                      "Scanline should not animate under reduceMotion")
    }

    func testScanlineAnimatedWhenMotionEnabled() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.sealedBy = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        let scanline = view.territoryScanlineNode(forFaceId: faceId)
        XCTAssertNotNil(scanline?.action(forKey: "scanlineTravel"),
                        "Scanline should animate when motion is enabled")
    }

    /// Grid lines carry a grid-energy pulse action when motion is enabled.
    func testGridLinesHaveEnergyPulse() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: nil)
        XCTAssertGreaterThan(view.gridLineNodeCount(), 0, "Grid lines should be tracked")
        XCTAssertTrue(view.gridLineHasEnergyPulse(),
                      "Grid lines should carry an energy pulse when motion is enabled")
    }

    func testGridLinePulseDisabledUnderReduceMotion() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = true
        let board = BoardFactory.triad()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: nil)
        XCTAssertGreaterThan(view.gridLineNodeCount(), 0)
        XCTAssertFalse(view.gridLineHasEnergyPulse(),
                       "Grid energy pulse should be gated off under reduceMotion")
    }

    /// Depth-aware transparency: the nearest panel is more opaque than the
    /// farthest. Verified via the scene graph panel nodes.
    func testDepthAwarePanelTransparency() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.grandmaster()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: nil)
        let scene = try XCTUnwrap(view.sceneSnapshot())
        // Collect panel nodes by name and their transparency.
        var panels: [Int: CGFloat] = [:]
        scene.rootNode.enumerateChildNodes { node, _ in
            if let name = node.name, name.hasPrefix("panel-"),
               let idx = Int(name.dropFirst("panel-".count)),
               let t = node.geometry?.firstMaterial?.transparency {
                panels[idx] = t
            }
        }
        XCTAssertGreaterThanOrEqual(panels.count, 2, "Need >=2 panels to compare depth")
        // The grandmaster layout: plateau 0 is nearest (highest Z), plateau 5
        // is farthest (lowest Z). Near should be more opaque than far.
        let near = panels[0] ?? 0
        let far = panels[board.plateaus.count - 1] ?? 0
        XCTAssertGreaterThan(near, far,
                             "Nearest panel should be more opaque than farthest")
    }

    /// A state-change pulse is attached to a token when its owner changes.
    func testStateChangePulsesToken() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        let target = board.nodes.first { $0.kind == .standard }!.id
        XCTAssertFalse(view.tokenHasStatePulse(forNodeId: target),
                       "No pulse at rest")
        // Change the token's owner and reconfigure (dynamic update path).
        state.nodes[target]?.owner = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertTrue(view.tokenHasStatePulse(forNodeId: target),
                      "Token should pulse when its owner changes")
    }

    func testStateChangePulseDisabledUnderReduceMotion() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = true
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        let target = board.nodes.first { $0.kind == .standard }!.id
        state.nodes[target]?.owner = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertFalse(view.tokenHasStatePulse(forNodeId: target),
                       "State-change pulse should be gated off under reduceMotion")
    }

    /// A newly controlled territory face receives a state-change pulse.
    func testTerritoryStatePulseOnNewControl() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        let faceId = board.faces.first!.id
        state.faces[faceId]?.controller = .player1
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertTrue(view.territoryHasStatePulse(forFaceId: faceId),
                      "Newly controlled face should pulse")
    }

    /// An edge bloom is hidden when the edge becomes severed.
    func testEdgeBloomHiddenWhenSevered() {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        let edgeId = board.edges.first!.id
        XCTAssertFalse(view.edgeBloomNode(forEdgeId: edgeId)?.isHidden ?? true)
        // Sever the edge and reconfigure (dynamic update path).
        state.edges[edgeId]?.severed = true
        view.configure(board: board, state: state, selectedNodeId: nil)
        XCTAssertTrue(view.edgeBloomNode(forEdgeId: edgeId)?.isHidden ?? false,
                      "Edge bloom should be hidden when the edge is severed")
    }

    // MARK: - Segment 9: reference-comparison adjustments

    /// Non-severed edges render at reduced opacity (0.60, not 1.0) to soften
    /// the contrast between topology lines and the panel background, matching
    /// the reference stills' soft projected-light look.
    func testNonSeveredEdgeOpacityIsSoftened() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        view.configure(board: board, state: state, selectedNodeId: nil)
        // Verify via the scene graph: edge nodes are named "edge:<id>".
        // All edges start non-severed, so each should be at 0.60 opacity.
        guard let scene = view.sceneSnapshot() else {
            throw XCTSkip("SceneKit scene unavailable in headless test host")
        }
        var checked = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let name = node.name, name.hasPrefix("edge:") else { return }
            XCTAssertEqual(node.opacity, 0.60, accuracy: 0.01,
                           "Non-severed edge \(name) should be at 0.60 opacity")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "Should have checked at least one edge")
    }

    /// Panel transparency is in the Segment 9 range (0.08..0.14), higher than
    /// the original 0.030..0.058, so the upright panels read as denser
    /// projected light matching the reference stills.
    func testPanelTransparencyInSegment9Range() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let board = BoardFactory.grandmaster()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: nil)
        let scene = try XCTUnwrap(view.sceneSnapshot())
        var minTransparency: CGFloat = .infinity
        var maxTransparency: CGFloat = 0
        scene.rootNode.enumerateChildNodes { node, _ in
            guard let name = node.name, name.hasPrefix("panel-"),
                  let t = node.geometry?.firstMaterial?.transparency else { return }
            minTransparency = min(minTransparency, t)
            maxTransparency = max(maxTransparency, t)
        }
        XCTAssertLessThan(minTransparency, .infinity, "Should have found panel nodes")
        XCTAssertGreaterThanOrEqual(minTransparency, 0.07,
                                    "Panel transparency should be >= 0.07 (Segment 9 range)")
        XCTAssertLessThanOrEqual(maxTransparency, 0.16,
                                 "Panel transparency should be <= 0.16 (Segment 9 range)")
    }

    /// The camera framing excludes the projector table and sensor rigs so the
    /// bright board content fills more of the viewport. Verified by checking
    /// that the camera distance is shorter than the old all-geometry framing.
    func testCameraFramingExcludesProps() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        let board = BoardFactory.grandmaster()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: nil)
        view.layoutSubtreeIfNeeded()
        guard let pov = view.sceneSnapshot()?.rootNode.childNode(
            withName: "board-camera", recursively: false) else {
            throw XCTSkip("Camera not available in headless test host")
        }
        // The camera should be closer than the old default (depth * 2.4 = ~26
        // for the grandmaster's 6 plateaus). With props excluded from framing,
        // the distance should be well under 26.
        let distance = simd_length(pov.simdWorldPosition)
        XCTAssertLessThan(distance, 26,
                          "Camera should frame board content, not distant props")
    }

    /// The grandmaster board renders a non-blank frame with content filling a
    /// meaningful portion of the viewport width (Segment 9 framing improvement).
    func testGrandmasterRenderFillsViewportWidth() throws {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 1200, height: 680))
        view.reduceMotion = true
        let board = BoardFactory.grandmaster()
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: board.anchors.player1.first)
        view.layoutSubtreeIfNeeded()
        guard let image = view.renderSnapshot(),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else {
            throw XCTSkip("Snapshot unavailable in headless test host")
        }
        var xMin = bitmap.pixelsWide, xMax = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let hi = max(c.redComponent, c.greenComponent, c.blueComponent)
                if hi > 0.2 { xMin = min(xMin, x); xMax = max(xMax, x) }
            }
        }
        let widthFrac = CGFloat(xMax - xMin) / CGFloat(bitmap.pixelsWide)
        // Segment 9: content should fill at least 50% of the viewport width
        // (improved from the baseline 49%). The reference fills ~100%.
        XCTAssertGreaterThan(widthFrac, 0.50,
                             "Board content should fill >50% of viewport width")
    }
}
