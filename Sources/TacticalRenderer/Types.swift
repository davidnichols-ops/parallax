import Foundation
import simd
import TacticalCore

/// Shared types between Swift and Metal. Must match the structs in Shaders.metal.
public struct Uniforms {
    public var viewMatrix: matrix_float4x4
    public var projectionMatrix: matrix_float4x4
    public var viewProjection: matrix_float4x4
    public var cameraPosition: SIMD3<Float>
    public var time: Float
    public var viewportSize: SIMD2<Float>
    public var pixelDensity: Float
    public var _padding: Float

    public init() {
        viewMatrix = matrix_identity_float4x4
        projectionMatrix = matrix_identity_float4x4
        viewProjection = matrix_identity_float4x4
        cameraPosition = SIMD3<Float>(0, 0, 10)
        time = 0
        viewportSize = SIMD2<Float>(1, 1)
        pixelDensity = 2
        _padding = 0
    }
}

public struct NodeInstance {
    public var position: SIMD3<Float>
    public var radius: Float
    public var color: SIMD4<Float>
    public var glowIntensity: Float
    public var selected: Float
    public var locked: Float
    public var _padding1: Float
    public var _padding2: Float

    public init(position: SIMD3<Float>, radius: Float, color: SIMD4<Float>,
                glow: Float = 0, selected: Float = 0, locked: Float = 0) {
        self.position = position
        self.radius = radius
        self.color = color
        self.glowIntensity = glow
        self.selected = selected
        self.locked = locked
        self._padding1 = 0
        self._padding2 = 0
    }
}

public struct EdgeInstance {
    public var start: SIMD3<Float>
    public var end: SIMD3<Float>
    public var thickness: Float
    public var color: SIMD4<Float>
    public var flux: Float
    public var severed: Float
    public var sealed: Float
    public var conduit: Float
    /// Phase offsets the travelling hologram pulse so adjacent arcs do not
    /// flash in lockstep.
    public var phase: Float

    public init(start: SIMD3<Float>, end: SIMD3<Float>, thickness: Float,
                color: SIMD4<Float>, flux: Float = 0, severed: Float = 0,
                sealed: Float = 0, conduit: Float = 0, phase: Float = 0) {
        self.start = start
        self.end = end
        self.thickness = thickness
        self.color = color
        self.flux = flux
        self.severed = severed
        self.sealed = sealed
        self.conduit = conduit
        self.phase = phase
    }
}

public struct FaceInstance {
    public var v0: SIMD3<Float>
    public var v1: SIMD3<Float>
    public var v2: SIMD3<Float>
    public var color: SIMD4<Float>
    public var alpha: Float
    public var _padding: (Float, Float, Float)

    public init(v0: SIMD3<Float>, v1: SIMD3<Float>, v2: SIMD3<Float>,
                color: SIMD4<Float>, alpha: Float = 0.15) {
        self.v0 = v0
        self.v1 = v1
        self.v2 = v2
        self.color = color
        self.alpha = alpha
        self._padding = (0, 0, 0)
    }
}

/// Ownership color palette. Never hue-only — ownership is also encoded by
/// shape (glyph on node) and position (anchor nodes are larger).
public enum OwnershipPalette {
    // The screen-reference language is a black field, gold wireframe, and
    // hot red tokens. Opponents differ by red/orange value rather than a
    // detached blue theme, while UI labels preserve the accessible identity.
    public static let neutral: SIMD4<Float> = SIMD4<Float>(1.0, 0.78, 0.26, 0.56)
    public static let player1: SIMD4<Float> = SIMD4<Float>(1.0, 0.06, 0.025, 1.0)
    public static let player2: SIMD4<Float> = SIMD4<Float>(1.0, 0.28, 0.055, 1.0)
    public static let severed: SIMD4<Float> = SIMD4<Float>(0.48, 0.03, 0.04, 0.82)
    public static let selected: SIMD4<Float> = SIMD4<Float>(1.0, 0.92, 0.38, 1.0)

    public static func color(for owner: Owner) -> SIMD4<Float> {
        switch owner {
        case .neutral: return neutral
        case .player1: return player1
        case .player2: return player2
        case .severed: return severed
        }
    }
}
