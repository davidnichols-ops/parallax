import Foundation
import Metal
import MetalKit
import simd
import TacticalCore

/// The Metal renderer. Manages device state, pipelines, and per-frame encoding.
/// Reads from a BoardDefinition + GameState snapshot each frame.
public final class Renderer: NSObject, MTKViewDelegate {

    public var board: BoardDefinition
    public var state: GameState
    public var selectedNodeId: String? = nil
    public var camera = Camera()
    public var enableFaces: Bool = true

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let library: MTLLibrary

    // Pipeline states
    private var nodePipeline: MTLRenderPipelineState?
    private var edgePipeline: MTLRenderPipelineState?
    private var facePipeline: MTLRenderPipelineState?

    // Geometry buffers (static)
    private var icoVertBuffer: MTLBuffer?
    private var icoNormBuffer: MTLBuffer?
    private var edgeQuadBuffer: MTLBuffer?

    // Uniforms buffer
    private var uniformsBuffer: MTLBuffer?

    // Instance buffers (rebuilt when state changes)
    private var nodeInstanceBuffer: MTLBuffer?
    private var edgeInstanceBuffer: MTLBuffer?
    private var faceInstanceBuffer: MTLBuffer?

    private var startTime: CFTimeInterval = 0
    private var frameCount: UInt64 = 0
    private var hasFramedBoard = false

    public init(device: MTLDevice, board: BoardDefinition, state: GameState) {
        self.device = device
        self.board = board
        self.state = state
        self.commandQueue = device.makeCommandQueue()!
        // Compile shaders from embedded source — avoids bundle loading issues in SPM.
        self.library = try! device.makeLibrary(source: ShaderSource.msl, options: nil)

        super.init()

        camera.target = MeshBuilder.boardCenter(board)
        buildPipelines()
        buildStaticBuffers()
    }

    // MARK: - Pipeline setup

    private func buildPipelines() {
        let nodeDesc = MTLRenderPipelineDescriptor()
        nodeDesc.label = "NodePipeline"
        nodeDesc.vertexFunction = library.makeFunction(name: "node_vertex")
        nodeDesc.fragmentFunction = library.makeFunction(name: "node_fragment")
        nodeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        nodeDesc.depthAttachmentPixelFormat = .depth32Float
        nodeDesc.colorAttachments[0].isBlendingEnabled = true
        nodeDesc.colorAttachments[0].rgbBlendOperation = .add
        nodeDesc.colorAttachments[0].alphaBlendOperation = .add
        nodeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        nodeDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        nodeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        nodeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let edgeDesc = MTLRenderPipelineDescriptor()
        edgeDesc.label = "EdgePipeline"
        edgeDesc.vertexFunction = library.makeFunction(name: "edge_vertex")
        edgeDesc.fragmentFunction = library.makeFunction(name: "edge_fragment")
        edgeDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        edgeDesc.depthAttachmentPixelFormat = .depth32Float
        edgeDesc.colorAttachments[0].isBlendingEnabled = true
        edgeDesc.colorAttachments[0].rgbBlendOperation = .add
        edgeDesc.colorAttachments[0].alphaBlendOperation = .add
        edgeDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        edgeDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        edgeDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        edgeDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let faceDesc = MTLRenderPipelineDescriptor()
        faceDesc.label = "FacePipeline"
        faceDesc.vertexFunction = library.makeFunction(name: "face_vertex")
        faceDesc.fragmentFunction = library.makeFunction(name: "face_fragment")
        faceDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        faceDesc.depthAttachmentPixelFormat = .depth32Float
        faceDesc.colorAttachments[0].isBlendingEnabled = true
        faceDesc.colorAttachments[0].rgbBlendOperation = .add
        faceDesc.colorAttachments[0].alphaBlendOperation = .add
        faceDesc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        faceDesc.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        faceDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        faceDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            nodePipeline = try device.makeRenderPipelineState(descriptor: nodeDesc)
            edgePipeline = try device.makeRenderPipelineState(descriptor: edgeDesc)
            facePipeline = try device.makeRenderPipelineState(descriptor: faceDesc)
        } catch {
            print("Pipeline creation failed: \(error)")
        }
    }

    private func buildStaticBuffers() {
        // Icosahedron vertices
        icoVertBuffer = makeBuffer(from: MeshBuilder.icoVertices)
        // Icosahedron normals
        icoNormBuffer = makeBuffer(from: MeshBuilder.icoNormals)
        // Edge quad vertices
        edgeQuadBuffer = makeBuffer(from: MeshBuilder.edgeQuadVerts)
        // Uniforms buffer
        uniformsBuffer = device.makeBuffer(length: MemoryLayout<Uniforms>.size, options: [])
    }

    private func makeBuffer<T>(from array: [T]) -> MTLBuffer? {
        array.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!,
                              length: ptr.count * MemoryLayout<T>.size,
                              options: [])
        }
    }

    // MARK: - Instance buffer rebuild

    /// Rebuild instance buffers from current board + state. Call when state changes.
    public func rebuildInstances() {
        let nodes = MeshBuilder.nodeInstances(board: board, state: state, selectedNodeId: selectedNodeId)
        let edges = MeshBuilder.edgeInstances(board: board, state: state)
        let faces = enableFaces ? MeshBuilder.faceInstances(board: board, state: state) : []

        nodeInstanceBuffer = makeInstanceBuffer(nodes)
        edgeInstanceBuffer = makeInstanceBuffer(edges)
        faceInstanceBuffer = makeInstanceBuffer(faces)
    }

    /// Return to a close, readable tactical framing rather than a generic
    /// scene-camera default.
    public func frameBoard() {
        camera.frame(center: MeshBuilder.boardCenter(board), extents: MeshBuilder.boardExtents(board))
        hasFramedBoard = true
    }

    private func makeInstanceBuffer<T>(_ instances: [T]) -> MTLBuffer? {
        guard !instances.isEmpty else { return nil }
        return instances.withUnsafeBufferPointer { ptr in
            device.makeBuffer(bytes: ptr.baseAddress!,
                              length: ptr.count * MemoryLayout<T>.size,
                              options: [])
        }
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        camera.aspect = Float(size.width / size.height)
        if !hasFramedBoard { frameBoard() }
    }

    public func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let desc = view.currentRenderPassDescriptor,
              let cmdBuf = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: desc) else { return }

        if startTime == 0 { startTime = CFAbsoluteTimeGetCurrent() }
        let elapsed = Float(CFAbsoluteTimeGetCurrent() - startTime)
        frameCount += 1

        // Update uniforms
        var uniforms = Uniforms()
        uniforms.viewMatrix = camera.viewMatrix
        uniforms.projectionMatrix = camera.projectionMatrix
        uniforms.viewProjection = camera.viewProjection
        uniforms.cameraPosition = camera.position
        uniforms.time = elapsed
        uniforms.viewportSize = SIMD2<Float>(Float(view.drawableSize.width), Float(view.drawableSize.height))
        uniforms.pixelDensity = Float(view.window?.screen?.backingScaleFactor ?? 2)

        if let ub = uniformsBuffer {
            memcpy(ub.contents(), &uniforms, MemoryLayout<Uniforms>.size)
        }

        encoder.pushDebugGroup("ParallaxRender")

        // Faces first (semi-transparent, behind everything)
        if let fp = facePipeline, let fb = faceInstanceBuffer, let ub = uniformsBuffer {
            encoder.setRenderPipelineState(fp)
            encoder.setVertexBuffer(ub, offset: 0, index: 0)
            encoder.setFragmentBuffer(ub, offset: 0, index: 0)
            encoder.setVertexBuffer(fb, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3,
                                   instanceCount: fb.length / MemoryLayout<FaceInstance>.size)
        }

        // Edges
        if let ep = edgePipeline, let eb = edgeInstanceBuffer, let ub = uniformsBuffer,
           let qb = edgeQuadBuffer {
            encoder.setRenderPipelineState(ep)
            encoder.setVertexBuffer(ub, offset: 0, index: 0)
            encoder.setFragmentBuffer(ub, offset: 0, index: 0)
            encoder.setVertexBuffer(eb, offset: 0, index: 1)
            encoder.setVertexBuffer(qb, offset: 0, index: 2)
            let edgeCount = eb.length / MemoryLayout<EdgeInstance>.size
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: edgeCount)
        }

        // Nodes (on top)
        if let np = nodePipeline, let nb = nodeInstanceBuffer, let ub = uniformsBuffer,
           let vb = icoVertBuffer, let nmb = icoNormBuffer {
            encoder.setRenderPipelineState(np)
            encoder.setVertexBuffer(ub, offset: 0, index: 0)
            encoder.setFragmentBuffer(ub, offset: 0, index: 0)
            encoder.setVertexBuffer(nb, offset: 0, index: 1)
            encoder.setVertexBuffer(vb, offset: 0, index: 2)
            encoder.setVertexBuffer(nmb, offset: 0, index: 3)
            let nodeCount = nb.length / MemoryLayout<NodeInstance>.size
            encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                   vertexCount: MeshBuilder.icoVertices.count,
                                   instanceCount: nodeCount)
        }

        encoder.popDebugGroup()
        encoder.endEncoding()
        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}
