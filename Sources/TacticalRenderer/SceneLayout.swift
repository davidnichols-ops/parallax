import Foundation
import simd
import TacticalCore

/// Pure, AppKit-free geometry for the upright layered holographic board.
///
/// This is the headless-testable core of the SceneKit layout used by
/// `BoardHostingView`. It computes panel dimensions, the depth span of the
/// plateau stack, and per-node world positions without touching SceneKit, so
/// renderer geometry/framing can be verified without a GPU or window.
public struct BoardSceneLayout: Sendable, Equatable {
    public let panelWidth: Float
    public let panelHeight: Float
    public let depthSpan: Float
    public let gridUnit: Float
    public let layerSpacing: Float
    public let panelMargin: Float
    /// Plateau index -> plane Z offset.
    public let planeZ: [Int: Float]
    /// Node id -> world position.
    public let nodePosition: [String: SIMD3<Float>]

    public var cameraTarget: SIMD3<Float> { SIMD3<Float>(0, -0.48, 0.35) }
    public var cameraDirection: SIMD3<Float> { simd_normalize(SIMD3<Float>(0.42, 0.24, 1)) }

    /// Fits the actual geometry in perspective, including the near projector.
    /// Centering a world-space bounding box leaves a large gap above the board:
    /// near objects project larger than the equally tall, more distant panes.
    public func perspectiveFrame(points: [SIMD3<Float>], aspect: Float,
                                 fovDegrees: Float) -> (target: SIMD3<Float>, distance: Float) {
        let finitePoints = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard !finitePoints.isEmpty else {
            return (cameraTarget, framingDistance(aspect: aspect, fovDegrees: fovDegrees))
        }
        let safeAspect = aspect.isFinite ? max(0.1, aspect) : 1
        let safeFOV = fovDegrees.isFinite ? min(100, max(10, fovDegrees)) : 48
        let tangentY = tan(safeFOV * .pi / 360) * 0.94
        let tangentX = tangentY * safeAspect
        let direction = cameraDirection
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), direction))
        let up = simd_cross(direction, right)
        var upperX = -Float.infinity, lowerX = Float.infinity
        var upperY = -Float.infinity, lowerY = Float.infinity
        var nearestDepth = -Float.infinity
        for point in finitePoints {
            let relative = point - cameraTarget
            let x = simd_dot(relative, right), y = simd_dot(relative, up)
            let z = simd_dot(relative, direction)
            upperX = max(upperX, x + tangentX * z)
            lowerX = min(lowerX, x - tangentX * z)
            upperY = max(upperY, y + tangentY * z)
            lowerY = min(lowerY, y - tangentY * z)
            nearestDepth = max(nearestDepth, z)
        }
        let distance = max(nearestDepth + 0.2,
                           (upperX - lowerX) / (2 * tangentX),
                           (upperY - lowerY) / (2 * tangentY))
        let target = cameraTarget + right * ((upperX + lowerX) * 0.5)
            + up * ((upperY + lowerY) * 0.5)
        return (target, distance)
    }

    /// Compute the layout for a board.
    public static func compute(for board: BoardDefinition,
                               gridUnit: Float = 1.5,
                               layerSpacing: Float = 2.4,
                               panelMargin: Float = 0.9) -> BoardSceneLayout {
        let maxX = max(1, board.nodes.map(\.x).max() ?? 1)
        let maxY = max(1, board.nodes.map(\.y).max() ?? 1)
        let panelWidth = Float(maxX + 1) * gridUnit + panelMargin * 2
        let panelHeight = Float(maxY + 1) * gridUnit + panelMargin * 2
        let centerPlateau = Float(board.plateaus.count - 1) * 0.5
        let depthSpan = Float(max(1, board.plateaus.count - 1)) * layerSpacing
        var planeZ: [Int: Float] = [:]
        for p in board.plateaus {
            planeZ[p.index] = (Float(p.index) - centerPlateau) * (-layerSpacing)
        }
        var positions: [String: SIMD3<Float>] = [:]
        for node in board.nodes {
            let localX = (Float(node.x) - Float(maxX) * 0.5) * gridUnit
            let localY = (Float(node.y) - Float(maxY) * 0.5) * gridUnit
            let z = planeZ[node.plateau] ?? 0
            positions[node.id] = SIMD3<Float>(localX, localY, z)
        }
        return BoardSceneLayout(panelWidth: panelWidth, panelHeight: panelHeight,
                                depthSpan: depthSpan, gridUnit: gridUnit,
                                layerSpacing: layerSpacing, panelMargin: panelMargin,
                                planeZ: planeZ, nodePosition: positions)
    }

    /// Camera distance that frames the upright board within a viewport of the
    /// given aspect (width/height) at the given vertical field of view in
    /// degrees. Pure function — used by both the live view and headless tests.
    public func framingDistance(aspect: Float, fovDegrees: Float) -> Float {
        let safeAspect = aspect.isFinite ? max(0.1, aspect) : 1
        let safeFOV = fovDegrees.isFinite ? min(100, max(10, fovDegrees)) : 48
        let verticalTangent = tan(safeFOV * .pi / 360)
        let horizontalTangent = verticalTangent * safeAspect
        let direction = cameraDirection
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), direction))
        let up = simd_cross(direction, right)
        // Include the projector and sensor arrays, not just the pane centers.
        // Segment 9: raised the projector table, so the minimum Y extent is
        // tighter (-0.75 vs -1.15). This lets the camera frame closer, filling
        // more of the viewport width to match the reference stills.
        let xExtent = panelWidth * 0.63 + 1.0
        let minimum = SIMD3<Float>(-xExtent, -panelHeight * 0.5 - 0.75, -depthSpan * 0.5 - 0.8)
        let maximum = SIMD3<Float>(xExtent, panelHeight * 0.5 + 0.2, depthSpan * 0.5 + 2.0)
        var distance: Float = 0
        for x in [minimum.x, maximum.x] {
            for y in [minimum.y, maximum.y] {
                for z in [minimum.z, maximum.z] {
                    let relative = SIMD3<Float>(x, y, z) - cameraTarget
                    let depth = simd_dot(relative, direction)
                    distance = max(distance, depth + abs(simd_dot(relative, right)) / horizontalTangent)
                    distance = max(distance, depth + abs(simd_dot(relative, up)) / verticalTangent)
                }
            }
        }
        return max(14, distance * 1.025)
    }
}
