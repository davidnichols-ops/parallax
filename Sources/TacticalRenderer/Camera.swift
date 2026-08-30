import Foundation
import simd

/// Interactive oblique tabletop camera used by the Metal renderer. The native
/// SceneKit board mirrors the same spherical orbit/pan model in its host view.
public struct Camera {
    public var target: SIMD3<Float>      // look-at point
    public var distance: Float           // distance from target
    public var azimuth: Float            // horizontal angle (radians)
    public var elevation: Float          // vertical angle (radians)
    public var fov: Float                // field of view (radians)
    public var near: Float
    public var far: Float
    public var aspect: Float
    private var homeTarget: SIMD3<Float>
    private var minDistance: Float
    private var maxDistance: Float
    private var panLimit: Float

    public init(target: SIMD3<Float> = SIMD3<Float>(0, 0, 0),
                distance: Float = 18,
                azimuth: Float = .pi * 0.25,
                elevation: Float = .pi * 0.2,
                fov: Float = .pi * 0.35,
                near: Float = 0.1,
                far: Float = 200,
                aspect: Float = 1.0) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = elevation
        self.fov = fov
        self.near = near
        self.far = far
        self.aspect = aspect
        self.homeTarget = target
        self.minDistance = 5
        self.maxDistance = 60
        self.panLimit = 6
    }

    /// Camera position in world space.
    public var position: SIMD3<Float> {
        let ce = cos(elevation)
        let se = sin(elevation)
        let ca = cos(azimuth)
        let sa = sin(azimuth)
        return target + SIMD3<Float>(distance * ce * sa,
                                       distance * se,
                                       distance * ce * ca)
    }

    /// View matrix (world → view).
    public var viewMatrix: matrix_float4x4 {
        let pos = position
        let forward = normalize(target - pos)
        let right = normalize(cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = cross(right, forward)
        let m = matrix_float4x4(
            SIMD4<Float>(right, 0),
            SIMD4<Float>(up, 0),
            SIMD4<Float>(-forward, 0),
            SIMD4<Float>(0, 0, 0, 1)
        )
        let t = matrix_float4x4(
            SIMD4<Float>(1, 0, 0, 0),
            SIMD4<Float>(0, 1, 0, 0),
            SIMD4<Float>(0, 0, 1, 0),
            SIMD4<Float>(-pos, 1)
        )
        return m * t
    }

    /// Perspective projection matrix.
    public var projectionMatrix: matrix_float4x4 {
        let f = 1.0 / tan(fov / 2)
        return matrix_float4x4(
            SIMD4<Float>(f / aspect, 0, 0, 0),
            SIMD4<Float>(0, f, 0, 0),
            SIMD4<Float>(0, 0, far / (far - near), 1),
            SIMD4<Float>(0, 0, -(far * near) / (far - near), 0)
        )
    }

    public var viewProjection: matrix_float4x4 {
        projectionMatrix * viewMatrix
    }

    public mutating func reset(to home: SIMD3<Float> = SIMD3<Float>(0, 0, 0)) {
        target = home
        homeTarget = home
        distance = max(minDistance, min(maxDistance, 18))
        azimuth = .pi * 0.06
        elevation = .pi * 0.30
    }

    /// Frames the actual holographic panels, leaving a deliberate small margin
    /// for their animated sensor trails without shrinking the playfield.
    public mutating func frame(center: SIMD3<Float>, extents: SIMD3<Float>) {
        homeTarget = center
        target = center
        // Fixed high three-quarter view: a readable tabletop perspective with
        // just enough depth to make the layered grid physical.
        azimuth = .pi * 0.06
        elevation = .pi * 0.30

        let safeAspect = max(aspect, 0.45)
        let verticalFOV = fov
        let horizontalFOV = 2 * atan(tan(verticalFOV * 0.5) * safeAspect)
        let heightDistance = extents.y / max(tan(verticalFOV * 0.5), 0.01)
        let widthDistance = extents.x / max(tan(horizontalFOV * 0.5), 0.01)
        // Perspective depth must sit behind the largest panel. A 12% margin
        // leaves the board large while avoiding clipping during small orbits.
        distance = max(heightDistance, widthDistance) + extents.z * 0.75
        distance *= 1.12
        minDistance = max(3.0, distance * 0.52)
        maxDistance = max(minDistance + 1, distance * 2.1)
        panLimit = max(1.0, max(extents.x, extents.y) * 0.55)
        distance = max(minDistance, min(maxDistance, distance))
    }
}
