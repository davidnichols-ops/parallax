import XCTest
import Metal
@testable import TacticalRenderer
import TacticalCore

final class HologramRendererTests: XCTestCase {
    func testEmbeddedMetalShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal is unavailable on this test host")
        }
        XCTAssertNoThrow(try device.makeLibrary(source: ShaderSource.msl, options: nil))
    }

    func testPlateausAreTabletopLayersSeparatedByHeight() {
        let board = BoardFactory.triad()
        let alpha = board.nodeMap["p0x0y0"]!
        let beta = board.nodeMap["p1x0y0"]!
        let alphaPosition = MeshBuilder.nodePosition(alpha, board: board)
        let betaPosition = MeshBuilder.nodePosition(beta, board: board)

        XCTAssertEqual(alphaPosition.x, betaPosition.x, accuracy: 0.0001)
        XCTAssertEqual(alphaPosition.z, betaPosition.z, accuracy: 0.0001)
        XCTAssertNotEqual(alphaPosition.y, betaPosition.y)
    }

    func testHologramEdgesIncludeDenseTabletopGrid() {
        let board = BoardFactory.triad()
        let state = GameState(board: board, matchSeed: 1)
        let instances = MeshBuilder.edgeInstances(board: board, state: state)

        // 3 layers × (4 horizontal + 4 vertical grid lines) accompany the
        // authored board edges. Sensor arcs are intentionally absent: only the
        // fixed board occupies the frame.
        XCTAssertGreaterThanOrEqual(instances.count, board.edges.count + 24)
    }
}
