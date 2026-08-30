import SwiftUI
import AppKit
import SceneKit
import TacticalCore

public enum TabletopControl: Sendable {
    case pulse
    case yield
    case pause
    case menu
    case help
}

/// Native fixed-perspective holographic board rendered with SceneKit.
///
/// The board is a stack of large upright translucent rectangular planes — one
/// per plateau — viewed from a fixed, slightly elevated angle. Each plane
/// carries concentric rectilinear teal outlines nesting inward, overlapping
/// lavender/chartreuse/yellow translucent fields, a gold grid, red/yellow ring
/// tokens at every node, and conduit edges stitching the layers together. A
/// pale perforated projector table with beveled tiers sits beneath the planes,
/// flanked by metallic fingertip sensor capsules with cables.
public struct BoardMetalView: NSViewRepresentable {
    public let board: BoardDefinition
    @Binding public var state: GameState
    @Binding public var selectedNodeId: String?
    @Binding public var cameraResetToken: Int
    public var onKeyEvent: ((NSEvent, Bool) -> Bool)?
    public var onFocusLost: (() -> Void)?
    public var onNodeSelected: ((String) -> Void)?
    public var onTabletopControl: ((TabletopControl) -> Void)?
    public var reduceMotion: Bool
    public var highContrast: Bool
    /// Segment 11 — transient feedback pulse the board animates when an action
    /// resolves (burst/flash/ripple/snapback). The renderer fires an accent only
    /// when `token` changes. nil when no pulse is active.
    public var feedbackPulse: BoardFeedbackPulse? = nil
    /// Segment 11 — commitment-window glow held on the targeted
    /// node/edge/face while a player's intent is locked/resolving. nil clears
    /// the glow; `.resolved` phase fades it out.
    public var commitmentGlow: BoardCommitmentGlow? = nil

    public init(board: BoardDefinition, state: Binding<GameState>,
                selectedNodeId: Binding<String?> = .constant(nil),
                cameraResetToken: Binding<Int> = .constant(0),
                onKeyEvent: ((NSEvent, Bool) -> Bool)? = nil,
                onFocusLost: (() -> Void)? = nil,
                onNodeSelected: ((String) -> Void)? = nil,
                onTabletopControl: ((TabletopControl) -> Void)? = nil,
                reduceMotion: Bool = false,
                highContrast: Bool = false,
                feedbackPulse: BoardFeedbackPulse? = nil,
                commitmentGlow: BoardCommitmentGlow? = nil) {
        self.board = board
        self._state = state
        self._selectedNodeId = selectedNodeId
        self._cameraResetToken = cameraResetToken
        self.onKeyEvent = onKeyEvent
        self.onFocusLost = onFocusLost
        self.onNodeSelected = onNodeSelected
        self.onTabletopControl = onTabletopControl
        self.reduceMotion = reduceMotion
        self.highContrast = highContrast
        self.feedbackPulse = feedbackPulse
        self.commitmentGlow = commitmentGlow
    }

    public func makeNSView(context: Context) -> BoardHostingView {
        let view = BoardHostingView()
        let selection = _selectedNodeId
        view.onNodeSelected = { nodeId in
            selection.wrappedValue = nodeId
            onNodeSelected?(nodeId)
        }
        view.onKeyEvent = onKeyEvent
        view.onFocusLost = onFocusLost
        view.onTabletopControl = onTabletopControl
        view.reduceMotion = reduceMotion
        view.highContrast = highContrast
        view.cameraResetToken = cameraResetToken
        view.feedbackPulse = feedbackPulse
        view.commitmentGlow = commitmentGlow
        view.configure(board: board, state: state, selectedNodeId: selectedNodeId)
        return view
    }

    public func updateNSView(_ view: BoardHostingView, context: Context) {
        let selection = _selectedNodeId
        view.onNodeSelected = { nodeId in
            selection.wrappedValue = nodeId
            onNodeSelected?(nodeId)
        }
        view.onKeyEvent = onKeyEvent
        view.onFocusLost = onFocusLost
        view.onTabletopControl = onTabletopControl
        view.reduceMotion = reduceMotion
        view.highContrast = highContrast
        view.cameraResetToken = cameraResetToken
        view.feedbackPulse = feedbackPulse
        view.commitmentGlow = commitmentGlow
        view.configure(board: board, state: state, selectedNodeId: selectedNodeId)
    }
}

/// A focusable AppKit board hosting a SceneKit view. Click a ring token to
/// select a node; keyboard events go directly to the game (the app shell owns
/// the global window keyboard monitor — this view only handles direct key
/// events and makes itself first responder).
public final class BoardHostingView: NSView {
    public var onKeyEvent: ((NSEvent, Bool) -> Bool)?
    public var onFocusLost: (() -> Void)?
    public var onNodeSelected: ((String) -> Void)?
    public var onTabletopControl: ((TabletopControl) -> Void)?
    public var reduceMotion: Bool = false
    public var highContrast: Bool = false
    /// Incremented by the app shell to restore the authored camera pose.
    public var cameraResetToken: Int = 0 {
        didSet { if cameraResetToken != oldValue { resetInteractiveCamera() } }
    }
    /// Segment 11 — transient feedback pulse + commitment glow observed from
    /// the app's duel-feel state. The renderer fires an accent only when the
    /// monotonic token changes. See `applyFeedbackPulse`/`applyCommitmentGlow`.
    public var feedbackPulse: BoardFeedbackPulse? = nil
    public var commitmentGlow: BoardCommitmentGlow? = nil

    private var scnView: SCNView!
    private var board: BoardDefinition?
    private var gameState: GameState?
    private var selectedNodeId: String?
    private var nodeTokens: [String: SCNNode] = [:]
    private var edgeNodes: [String: SCNNode] = [:]
    private var faceNodes: [String: SCNNode] = [:]
    private var gridLineNodes: [SCNNode] = []
    private var selectionRing: SCNNode?
    private var lastTokenResetToken: Int = -1
    private var currentLayout: UprightLayout?
    private var currentSceneLayout: BoardSceneLayout?
    private var contrastApplied: Bool = false
    // Previous-state tracking for state-change feedback pulses. Keys are
    // node/edge/face ids; values are the last rendered owner. A change between
    // configure() calls triggers a brief presentation pulse (gated on motion).
    private var previousTokenOwners: [String: Owner] = [:]
    private var previousEdgeOwners: [String: Owner] = [:]
    private var previousTerritoryControllers: [String: Owner] = [:]
    // Segment 11 — last-applied feedback/commitment tokens so the renderer
    // fires an accent only on a real change (re-trigger on repeat pulses).
    private var lastAppliedFeedbackToken: Int = -1
    private var lastAppliedCommitmentToken: Int = -1
    /// The currently attached commitment-glow node (persisted across configure
    /// calls until the phase resolves or the glow clears).
    private var commitmentGlowNode: SCNNode?

    private enum CameraGesture { case orbit, pan }
    private var cameraGesture: CameraGesture?
    private var lastCameraPoint: NSPoint = .zero
    private var cameraHasInteracted = false
    private var cameraTarget = SIMD3<Float>(0, 0, 0)
    private var cameraDistance: Float = 18
    private var cameraAzimuth: Float = .pi * 0.06
    private var cameraElevation: Float = .pi * 0.30

    // Layout constants — upright layered planes stacked along depth (Z).
    private let gridUnit: CGFloat = 1.5
    private let layerSpacing: CGFloat = 2.4
    private let panelMargin: CGFloat = 0.9

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupSceneView()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupSceneView()
    }

    public override var acceptsFirstResponder: Bool { true }

    // MARK: - Test accessors (internal; used by @testable renderer tests)

    /// Returns the selectable token node registered for a node id, if any.
    internal func tokenNode(forNodeId id: String) -> SCNNode? { nodeTokens[id] }

    /// Returns the territory face node registered for a face id, if any.
    /// Present only when the face has a controller or is sealed.
    internal func territoryFaceNode(forFaceId id: String) -> SCNNode? { faceNodes[id] }

    /// True when a selection ring is currently attached to a token.
    internal func hasSelectionRing() -> Bool { selectionRing != nil }

    /// Returns the bloom halo child node attached to a token, if any. Present
    /// only for owned (non-neutral) tokens after Segment 4 presentation work.
    internal func tokenBloomNode(forNodeId id: String) -> SCNNode? {
        nodeTokens[id]?.childNode(withName: "bloom", recursively: false)
    }

    /// Returns the bloom halo child node attached to an edge, if any. Present
    /// only for non-severed edges.
    internal func edgeBloomNode(forEdgeId id: String) -> SCNNode? {
        edgeNodes[id]?.childNode(withName: "bloom", recursively: false)
    }

    /// Returns the scanline shimmer child node attached to a sealed territory
    /// face, if any. Present only for sealed faces when reduceMotion is off.
    internal func territoryScanlineNode(forFaceId id: String) -> SCNNode? {
        faceNodes[id]?.childNode(withName: "scanline", recursively: false)
    }

    /// Number of grid-line nodes currently in the scene (for grid-energy
    /// animation assertions).
    internal func gridLineNodeCount() -> Int { gridLineNodes.count }

    /// True when a grid-line node carries a running SCNAction (the grid-energy
    /// pulse). Returns false under reduceMotion (animations are gated off).
    internal func gridLineHasEnergyPulse() -> Bool {
        guard !reduceMotion else { return false }
        return gridLineNodes.contains { !$0.actionKeys.isEmpty }
    }

    /// True when a territory face node carries a running state-change pulse
    /// action keyed under "statePulse".
    internal func territoryHasStatePulse(forFaceId id: String) -> Bool {
        faceNodes[id]?.action(forKey: "statePulse") != nil
    }

    /// True when an edge node carries a running state-change pulse action
    /// keyed under "statePulse".
    internal func edgeHasStatePulse(forEdgeId id: String) -> Bool {
        edgeNodes[id]?.action(forKey: "statePulse") != nil
    }

    /// True when a token node carries a running state-change pulse action
    /// keyed under "statePulse".
    internal func tokenHasStatePulse(forNodeId id: String) -> Bool {
        nodeTokens[id]?.action(forKey: "statePulse") != nil
    }

    // MARK: - Segment 11 test accessors (feedback accents + commitment glow)

    /// Returns the transient feedback-burst child node attached to a token,
    /// edge, or face node, if any. The burst is a short one-shot accent
    /// (expanding ring / flash / ripple / snapback) keyed under "feedbackBurst".
    internal func feedbackBurstNode(forNodeId id: String) -> SCNNode? {
        nodeTokens[id]?.childNode(withName: "feedbackBurst", recursively: false)
    }
    internal func feedbackBurstNode(forEdgeId id: String) -> SCNNode? {
        edgeNodes[id]?.childNode(withName: "feedbackBurst", recursively: false)
    }
    internal func feedbackBurstNode(forFaceId id: String) -> SCNNode? {
        faceNodes[id]?.childNode(withName: "feedbackBurst", recursively: false)
    }

    /// True when a feedback burst action is currently running on the given
    /// node/edge/face. The action lives on the transient burst child node, so
    /// this looks up the child and checks its keyed action. Returns false under
    /// reduceMotion (bursts are gated off).
    internal func hasFeedbackBurst(forNodeId id: String) -> Bool {
        feedbackBurstNode(forNodeId: id)?.action(forKey: "feedbackBurst") != nil
    }
    internal func hasFeedbackBurst(forEdgeId id: String) -> Bool {
        feedbackBurstNode(forEdgeId: id)?.action(forKey: "feedbackBurst") != nil
    }
    internal func hasFeedbackBurst(forFaceId id: String) -> Bool {
        feedbackBurstNode(forFaceId: id)?.action(forKey: "feedbackBurst") != nil
    }

    /// The last feedback pulse token the renderer applied. -1 before any pulse.
    internal var appliedFeedbackToken: Int { lastAppliedFeedbackToken }

    /// Returns the persistent commitment-glow child node attached to a token,
    /// edge, or face node, if any. Present while a commitment window is locked
    /// or resolving; removed after the resolved-phase fade.
    internal func commitmentGlowNode(forNodeId id: String) -> SCNNode? {
        nodeTokens[id]?.childNode(withName: "commitmentGlow", recursively: false)
    }
    internal func commitmentGlowNode(forEdgeId id: String) -> SCNNode? {
        edgeNodes[id]?.childNode(withName: "commitmentGlow", recursively: false)
    }
    internal func commitmentGlowNode(forFaceId id: String) -> SCNNode? {
        faceNodes[id]?.childNode(withName: "commitmentGlow", recursively: false)
    }

    /// The last commitment-glow token the renderer applied. -1 before any glow.
    internal var appliedCommitmentToken: Int { lastAppliedCommitmentToken }

    /// Returns the current SceneKit scene, or nil if none is installed.
    internal func sceneSnapshot() -> SCNScene? { scnView.scene }

    /// True when the SCNView is rendering continuously.
    internal func rendersContinuouslyEnabled() -> Bool { scnView.rendersContinuously }

    // MARK: - Segment 17 test accessors (interactive camera state)

    /// True once the user has orbited/panned/zoomed (camera left auto-fit).
    internal var testCameraHasInteracted: Bool { cameraHasInteracted }
    /// Current orbit azimuth (radians).
    internal var testCameraAzimuth: Float { cameraAzimuth }
    /// Current orbit elevation (radians), clamped to [.pi*0.08, .pi*0.46].
    internal var testCameraElevation: Float { cameraElevation }
    /// Current camera distance from the target.
    internal var testCameraDistance: Float { cameraDistance }
    /// Current camera pan target.
    internal var testCameraTarget: SIMD3<Float> { cameraTarget }
    /// The active camera gesture (.orbit/.pan during a drag, nil otherwise).
    internal var testCameraGesture: String? {
        switch cameraGesture { case .orbit: return "orbit"; case .pan: return "pan"; case nil: return nil }
    }

    /// Reset the interactive camera back to the auto-fit defaults. Mirrors the
    /// `resetCamera()` token path so tests can verify reset restores defaults.
    internal func testResetInteractiveCamera() { resetInteractiveCamera() }

    // MARK: - Segment 17 test accessors (mouse picking)

    /// The node ids of all token nodes currently registered for picking.
    internal func testTokenNodeIds() -> [String] { Array(nodeTokens.keys) }

    /// The screen-space point of a token node, for synthesizing a mouseDown
    /// at a known token. Returns nil if the token is not registered or does
    /// not project into the view's depth range.
    internal func testProjectedPoint(forNodeId id: String) -> NSPoint? {
        projectedPoint(forNodeID: id)
    }

    /// The window-space click point for a token node, reversing the
    /// `mouseDown` coordinate conversions (scnView space → board view space →
    /// window space) so a synthetic `mouseDown` event lands on the token.
    internal func testWindowClickPoint(forNodeId id: String) -> NSPoint? {
        guard let scnPoint = projectedPoint(forNodeID: id) else { return nil }
        // Reverse: scnView space → board view space → window space.
        let local = convert(scnPoint, from: scnView)
        return convert(local, to: nil)
    }

    /// Renders an offscreen snapshot of the current scene. Returns nil if the
    /// host cannot produce a bitmap (e.g. no graphics context in pure headless).
    public func renderSnapshot() -> NSImage? {
        guard let scnView else { return nil }
        // SCNView.snapshot() renders the current scene into an NSImage. It
        // requires a render context; in a windowless test host it may return
        // nil, in which case the caller skips rather than fails.
        return scnView.snapshot()
    }

    private func setupSceneView() {
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0.012, green: 0.010, blue: 0.018, alpha: 1).cgColor
        scnView = SCNView()
        scnView.translatesAutoresizingMaskIntoConstraints = false
        scnView.backgroundColor = NSColor(calibratedRed: 0.012, green: 0.010, blue: 0.018, alpha: 1)
        scnView.scene = SCNScene()
        // Default lighting gives the scene a base illumination before the custom
        // holographic lights are attached.
        scnView.autoenablesDefaultLighting = true
        // The hosting view owns all mouse/keyboard interaction. The SCNView is a
        // pure render surface: no built-in camera control, no default event
        // handling, and it never becomes first responder. Mouse hits are routed
        // back up to BoardHostingView via the overridden hitTest(_:).
        scnView.allowsCameraControl = false
        scnView.rendersContinuously = !reduceMotion
        scnView.preferredFramesPerSecond = 60
        scnView.antialiasingMode = .multisampling2X
        addSubview(scnView)
        NSLayoutConstraint.activate([
            scnView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scnView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scnView.topAnchor.constraint(equalTo: topAnchor),
            scnView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        // A minimal scene is installed immediately so the view has content
        // before a board is configured.
        installBaseScene()
    }

    /// Route all hit testing to this hosting view so the embedded SCNView never
    /// intercepts mouse events. The SCNView remains a render-only surface.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        return self
    }

    public func configure(board: BoardDefinition, state: GameState, selectedNodeId: String?) {
        let boardChanged = self.board?.id != board.id || self.board?.version != board.version
        let contrastChanged = self.contrastApplied != highContrast
        self.board = board
        self.gameState = state
        self.selectedNodeId = selectedNodeId
        if boardChanged || contrastChanged {
            self.contrastApplied = highContrast
            rebuildScene()
        } else {
            updateDynamicContent()
        }
        updateSelectionRing()
        // Segment 11 — wire the transient duel-feel state into board accents.
        // Applied after the scene/dynamic content so target nodes exist.
        applyCommitmentGlow()
        applyFeedbackPulse()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    public override func becomeFirstResponder() -> Bool { true }

    public override func resignFirstResponder() -> Bool {
        onFocusLost?()
        return true
    }

    // MARK: - Mouse / hit testing

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let local = convert(event.locationInWindow, from: nil)
        if event.type == .rightMouseDown || event.modifierFlags.contains(.option) {
            cameraGesture = event.modifierFlags.contains(.shift) ? .pan : .orbit
            lastCameraPoint = local
            cameraHasInteracted = true
            return
        }
        let point = scnView.convert(local, from: self)
        if let id = pickNodeID(at: point) { onNodeSelected?(id) }
    }

    public override func rightMouseDown(with event: NSEvent) {
        mouseDown(with: event)
    }

    public override func mouseDragged(with event: NSEvent) {
        guard let gesture = cameraGesture else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = Float(point.x - lastCameraPoint.x)
        let dy = Float(point.y - lastCameraPoint.y)
        lastCameraPoint = point
        switch gesture {
        case .orbit:
            cameraAzimuth -= dx * 0.008
            cameraElevation = min(.pi * 0.46, max(.pi * 0.08, cameraElevation + dy * 0.008))
        case .pan:
            let right = SIMD3<Float>(cosf(cameraAzimuth), 0, -sinf(cameraAzimuth))
            let scale = max(0.002, cameraDistance * 0.0018)
            cameraTarget += (-dx * scale) * right + SIMD3<Float>(0, dy * scale, 0)
        }
        applyInteractiveCamera()
    }

    public override func mouseUp(with event: NSEvent) {
        cameraGesture = nil
    }

    public override func rightMouseUp(with event: NSEvent) {
        cameraGesture = nil
    }

    public override func scrollWheel(with event: NSEvent) {
        cameraHasInteracted = true
        cameraDistance = min(cameraDistance * 1.35, max(7, cameraDistance * expf(-Float(event.scrollingDeltaY) * 0.08)))
        applyInteractiveCamera()
    }

    /// Ring centers are intentionally hollow. Screen-space picking includes
    /// their centers instead of requiring a click on a two-pixel torus edge.
    internal func pickNodeID(at point: NSPoint) -> String? {
        var nearest: (id: String, distance: CGFloat, depth: CGFloat)?
        for (id, token) in nodeTokens {
            let projected = scnView.projectPoint(token.worldPosition)
            guard projected.z >= 0, projected.z <= 1 else { continue }
            let x = CGFloat(projected.x) - point.x
            let y = CGFloat(projected.y) - point.y
            let distance = x*x + y*y
            guard distance <= 18*18 else { continue }
            if nearest == nil || distance < nearest!.distance - 0.01 ||
                (abs(distance - nearest!.distance) < 0.01 && projected.z < nearest!.depth) {
                nearest = (id, distance, projected.z)
            }
        }
        return nearest?.id
    }

    internal func projectedPoint(forNodeID id: String) -> NSPoint? {
        guard let node = nodeTokens[id] else { return nil }
        let point = scnView.projectPoint(node.worldPosition)
        return NSPoint(x: CGFloat(point.x), y: CGFloat(point.y))
    }

    // MARK: - Keyboard (direct only; no global/local monitor)

    public override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event, true) != true { super.keyDown(with: event) }
    }

    public override func keyUp(with event: NSEvent) {
        if onKeyEvent?(event, false) != true { super.keyUp(with: event) }
    }

    // MARK: - Scene construction

    /// Installs a non-empty scene (projector table + lights) so the view has
    /// content before a board is configured.
    private func installBaseScene() {
        guard let scene = scnView.scene else { return }
        scene.background.contents = NSColor(calibratedRed: 0.012, green: 0.010, blue: 0.018, alpha: 1)
        addLighting(to: scene.rootNode)
        addProjectorTable(to: scene.rootNode, planeWidth: 8, planeHeight: 8)
        addSensorRigs(to: scene.rootNode, planeWidth: 8, planeHeight: 8)
        installFixedCamera()
    }

    /// Re-frames the camera whenever the view is laid out / resized. Before the
    /// first gesture this fits the authored pose; after that it preserves the
    /// player's orbit/pan and only updates the fit distance when necessary.
    public override func layout() {
        super.layout()
        reframeCamera()
    }

    /// Recomputes the fixed camera distance from the current bounds aspect and
    /// the configured board extents. Called on layout and on rebuild.
    private func reframeCamera() {
        guard let pov = scnView.pointOfView, let camera = pov.camera else { return }
        let aspect = max(0.1, Float(sceneFrame().width) / max(1, Float(sceneFrame().height)))
        let layout = currentSceneLayout
            ?? BoardSceneLayout.compute(for: BoardFactory.triad())
        var points: [SIMD3<Float>] = []
        // Segment 9: frame the camera on the board content only — panels,
        // tokens, edges, territory faces, grid lines — NOT the projector table
        // or sensor rigs/cables. Those props extend wide and tall but are dim;
        // including them pushes the camera too far back, leaving the bright
        // hologram filling only half the viewport width. The reference stills
        // show the hologram filling the full frame. Props remain visible at
        // the frame edges, just excluded from the framing calculation.
        let boardNodes: [SCNNode] = {
            var nodes = gridLineNodes + Array(nodeTokens.values) +
                Array(edgeNodes.values) + Array(faceNodes.values)
            // Panel nodes are named "panel-<index>"; collect them from the root.
            scnView.scene?.rootNode.enumerateChildNodes { node, _ in
                if node.name?.hasPrefix("panel-") == true { nodes.append(node) }
            }
            return nodes
        }()
        for node in boardNodes {
            guard !node.isHidden, node.opacity > 0, let geometry = node.geometry else { continue }
            let (low, high) = geometry.boundingBox
            for x in [Float(low.x), Float(high.x)] {
                for y in [Float(low.y), Float(high.y)] {
                    for z in [Float(low.z), Float(high.z)] {
                        let world = node.simdWorldTransform * SIMD4<Float>(x, y, z, 1)
                        points.append(SIMD3<Float>(world.x, world.y, world.z))
                    }
                }
            }
        }
        let (target, distance) = layout.perspectiveFrame(
            points: points, aspect: aspect, fovDegrees: Float(camera.fieldOfView))
        if !cameraHasInteracted {
            cameraTarget = target
            cameraDistance = distance
        } else {
            cameraDistance = max(cameraDistance, distance * 0.82)
        }
        applyInteractiveCamera()
        camera.orthographicScale = 1.0
    }

    private func applyInteractiveCamera() {
        guard let pov = scnView.pointOfView else { return }
        let horizontal = cosf(cameraElevation)
        let direction = SIMD3<Float>(sinf(cameraAzimuth) * horizontal,
                                     sinf(cameraElevation),
                                     cosf(cameraAzimuth) * horizontal)
        let position = cameraTarget + direction * cameraDistance
        pov.simdPosition = position
        pov.look(at: SCNVector3(cameraTarget.x, cameraTarget.y, cameraTarget.z),
                 up: SCNVector3(0, 1, 0), localFront: SCNVector3(0, 0, -1))
    }

    private func resetInteractiveCamera() {
        cameraHasInteracted = false
        cameraGesture = nil
        cameraAzimuth = .pi * 0.06
        cameraElevation = .pi * 0.30
        reframeCamera()
    }

    private func sceneFrame() -> CGRect { scnView.bounds }

    private func rebuildScene() {
        guard let board, let gameState else { return }
        let scene = SCNScene()
        scene.background.contents = NSColor(calibratedRed: 0.012, green: 0.010, blue: 0.018, alpha: 1)
        nodeTokens.removeAll()
        edgeNodes.removeAll()
        faceNodes.removeAll()
        gridLineNodes.removeAll()
        selectionRing = nil
        previousTokenOwners.removeAll()
        previousEdgeOwners.removeAll()
        previousTerritoryControllers.removeAll()
        // Segment 11 — reset feedback/commitment tracking on a fresh scene so
        // the first configure after a rebuild does not fire a stale accent.
        commitmentGlowNode?.removeFromParentNode()
        commitmentGlowNode = nil
        lastAppliedFeedbackToken = -1
        lastAppliedCommitmentToken = -1

        addLighting(to: scene.rootNode)

        let layout = uprightLayout(for: board)
        for plateau in board.plateaus {
            addUprightPanel(to: scene.rootNode, plateau: plateau, layout: layout)
            addConcentricOutlines(to: scene.rootNode, plateau: plateau, layout: layout)
            addColoredFields(to: scene.rootNode, plateau: plateau, layout: layout)
            addGridLines(to: scene.rootNode, board: board, plateau: plateau, layout: layout)
        }
        addTerritoryFaces(to: scene.rootNode, board: board, state: gameState, layout: layout)
        addEdges(to: scene.rootNode, board: board, state: gameState, layout: layout)
        addNodeTokens(to: scene.rootNode, board: board, state: gameState, layout: layout)
        addProjectorTable(to: scene.rootNode, planeWidth: layout.panelWidth, planeHeight: layout.panelHeight)
        addSensorRigs(to: scene.rootNode, planeWidth: layout.panelWidth, planeHeight: layout.panelHeight)
        currentLayout = layout

        scnView.scene = scene
        // Attach the camera to the NEW scene; assigning a different scene after
        // installing it discards its point of view and breaks the framing.
        installFixedCamera(layout: layout)
        scnView.rendersContinuously = !reduceMotion
        updateSelectionRing()
        reframeCamera()
        // Seed previous-state tracking so the first dynamic update does not
        // fire a state-change pulse for every node/edge/face.
        for node in board.nodes {
            let ns = gameState.nodes[node.id] ?? NodeState()
            previousTokenOwners[node.id] = ns.owner
        }
        for edge in board.edges {
            let es = gameState.edges[edge.id] ?? EdgeState()
            previousEdgeOwners[edge.id] = es.owner
        }
        for face in board.faces {
            let fs = gameState.faces[face.id] ?? FaceState()
            previousTerritoryControllers[face.id] = fs.controller ?? fs.sealedBy
        }
    }

    private func updateDynamicContent() {
        guard let board, let gameState else { return }
        scnView.rendersContinuously = !reduceMotion
        // Refresh token colors and edge colors without rebuilding geometry.
        for node in board.nodes {
            guard let token = nodeTokens[node.id] else { continue }
            let ns = gameState.nodes[node.id] ?? NodeState()
            token.geometry?.firstMaterial?.diffuse.contents = tokenColor(for: ns.owner)
            token.geometry?.firstMaterial?.emission.contents = tokenEmission(for: ns.owner, influence: ns.influence)
            if let core = token.childNode(withName: "core", recursively: false) {
                core.geometry?.firstMaterial?.diffuse.contents = tokenColor(for: ns.owner)
                core.isHidden = ns.owner == .neutral
            }
            // Sync the projection bloom: owned tokens carry a bloom child,
            // neutral tokens do not. Update its color when the owner stays.
            let bloomColor = tokenEmission(for: ns.owner, influence: ns.influence)
            if let bloom = token.childNode(withName: "bloom", recursively: false) {
                if ns.owner == .neutral {
                    bloom.removeFromParentNode()
                } else {
                    bloom.geometry?.firstMaterial?.diffuse.contents = bloomColor.withAlphaComponent(0.5)
                    bloom.geometry?.firstMaterial?.emission.contents = bloomColor.withAlphaComponent(0.8)
                }
            } else if ns.owner != .neutral {
                let ringRadius: CGFloat = node.kind == .anchor ? 0.26 : (node.kind == .conduit ? 0.20 : 0.17)
                addTokenBloom(to: token, radius: ringRadius, color: bloomColor)
            }
            // State-change feedback: pulse when a token's owner changes.
            if previousTokenOwners[node.id] != ns.owner {
                attachStatePulse(to: token)
            }
            previousTokenOwners[node.id] = ns.owner
        }
        for edge in board.edges {
            guard let rendered = edgeNodes[edge.id], let es = gameState.edges[edge.id] else { continue }
            let color = edgeColor(for: es.owner, kind: edge.kind)
            rendered.geometry?.firstMaterial?.diffuse.contents = color
            rendered.geometry?.firstMaterial?.emission.contents = color
            rendered.opacity = es.severed ? 0.16 : 0.60
            // Sync edge bloom: hide when severed, show/update when live.
            if let bloom = rendered.childNode(withName: "bloom", recursively: false) {
                bloom.isHidden = es.severed
                bloom.geometry?.firstMaterial?.diffuse.contents = color
                bloom.geometry?.firstMaterial?.emission.contents =
                    color.withAlphaComponent(min(1, color.alphaComponent * 1.4))
            }
            // State-change feedback: pulse when an edge's owner changes.
            if previousEdgeOwners[edge.id] != es.owner {
                attachStatePulse(to: rendered)
            }
            previousEdgeOwners[edge.id] = es.owner
        }
        updateTerritoryFaces(board: board, state: gameState)
        // Record territory controllers for next-change detection.
        for face in board.faces {
            let fs = gameState.faces[face.id] ?? FaceState()
            previousTerritoryControllers[face.id] = fs.controller ?? fs.sealedBy
        }
        updateSelectionRing()
    }

    /// Attaches a brief one-shot state-change pulse to a node. The pulse
    /// scales the node up then back over ~0.4s, keyed under "statePulse" so it
    /// can be detected by tests and replaced if another change arrives. Gated
    /// off under reduceMotion (the node simply stays at its resting scale).
    private func attachStatePulse(to node: SCNNode) {
        guard !reduceMotion else { return }
        let pulse = SCNAction.sequence([
            SCNAction.scale(to: 1.18, duration: 0.18),
            SCNAction.scale(to: 1.0, duration: 0.22)
        ])
        node.runAction(pulse, forKey: "statePulse")
    }

    // MARK: - Segment 11 — duel-feel feedback accents + commitment glow

    /// Apply the latest feedback pulse as a board accent. Fires only when the
    /// pulse `token` differs from the last applied token (so repeat pulses
    /// re-trigger). The token is consumed regardless of reduceMotion so a
    /// motion toggle does not replay a stale accent; the visual is gated off
    /// under reduceMotion. Never mutates engine state.
    private func applyFeedbackPulse() {
        guard let pulse = feedbackPulse,
              pulse.token != lastAppliedFeedbackToken else { return }
        lastAppliedFeedbackToken = pulse.token
        guard !reduceMotion else { return }
        switch pulse.kind {
        case .pulse, .contested:
            if let id = pulse.targetNode, let token = nodeTokens[id] {
                attachNodeBurst(to: token, color: feedbackColor(for: pulse))
            }
        case .forge:
            if let id = pulse.targetEdge, let edge = edgeNodes[id] {
                attachEdgeFlash(to: edge, color: feedbackColor(for: pulse))
            }
        case .sever:
            if let id = pulse.targetEdge, let edge = edgeNodes[id] {
                attachEdgeFlash(to: edge, color: severColor)
                attachSnapback(to: edge, color: severColor)
            }
        case .seal:
            if let id = pulse.targetFace, let face = faceNodes[id] {
                attachNodeBurst(to: face, color: feedbackColor(for: pulse))
            }
        case .counter, .traverse:
            if let id = pulse.targetEdge, let edge = edgeNodes[id] {
                attachEdgeFlash(to: edge, color: feedbackColor(for: pulse))
            }
        case .yield:
            // Yield is a deliberate pass — an ambient ripple on the selected
            // node (or the first available token when nothing is selected) so
            // the pass reads as a visible "step back" rather than silence.
            let host = selectedNodeId.flatMap { nodeTokens[$0] }
                ?? nodeTokens.values.first
            if let host { attachYieldRipple(to: host) }
        case .reject:
            // A rejected action snaps back on its intended target; if the
            // target is unknown, fall back to the selected node so the player
            // sees the "no" cue on what they were aiming at.
            let host = pulse.targetNode.flatMap { nodeTokens[$0] }
                ?? pulse.targetEdge.flatMap { edgeNodes[$0] }
                ?? pulse.targetFace.flatMap { faceNodes[$0] }
                ?? selectedNodeId.flatMap { nodeTokens[$0] }
            if let host { attachSnapback(to: host, color: rejectColor) }
        }
    }

    /// Apply the commitment-window glow on the targeted node/edge/face. The
    /// glow attaches when the window opens, persists through `.locked`/
    /// `.resolving`, and fades out when the phase reaches `.resolved`. A nil
    /// glow (window cleared) removes it. The token is consumed on every change
    /// so phase transitions re-apply. The glow node is created even under
    /// reduceMotion (a static highlight of the locked-in target is an
    /// accessibility cue); only its pulse animation is gated off.
    private func applyCommitmentGlow() {
        guard let glow = commitmentGlow,
              glow.token != lastAppliedCommitmentToken else {
        // No token change — but if the glow was cleared upstream and the view
        // was rebuilt, ensure no stale glow lingers.
            if commitmentGlow == nil, commitmentGlowNode != nil {
                removeCommitmentGlow()
            }
            return
        }
        lastAppliedCommitmentToken = glow.token
        // Resolve the target host node for the glow.
        let host: SCNNode? = glow.targetNode.flatMap { nodeTokens[$0] }
            ?? glow.targetEdge.flatMap { edgeNodes[$0] }
            ?? glow.targetFace.flatMap { faceNodes[$0] }
        guard let host else {
            removeCommitmentGlow()
            return
        }
        if glow.phase == .resolved {
            // Fade the existing glow out and remove it; the exchange is done.
            fadeOutCommitmentGlow()
            return
        }
        attachCommitmentGlow(to: host, player: glow.player, phase: glow.phase)
    }

    /// A short expanding-ring burst attached as a child of a token/face node.
    /// The ring scales out and fades, then removes itself. Keyed under
    /// "feedbackBurst" so a new pulse replaces an in-flight burst.
    private func attachNodeBurst(to host: SCNNode, color: NSColor) {
        removeFeedbackBurst(from: host)
        let ring = SCNTorus(ringRadius: 0.20, pipeRadius: 0.020)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.9)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        ring.firstMaterial = mat
        let node = SCNNode(geometry: ring)
        node.name = "feedbackBurst"
        node.simdPosition = SIMD3<Float>(0, 0.12, 0)
        node.renderingOrder = 90
        host.addChildNode(node)
        let expand = SCNAction.sequence([
            SCNAction.scale(to: 2.4, duration: 0.22),
            SCNAction.fadeOpacity(to: 0.0, duration: 0.18),
            SCNAction.removeFromParentNode()
        ])
        node.runAction(expand, forKey: "feedbackBurst")
    }

    /// A brief additive flash along an edge: a wide low-alpha cylinder child
    /// whose emission spikes then fades. Keyed under "feedbackBurst".
    private func attachEdgeFlash(to edge: SCNNode, color: NSColor) {
        removeFeedbackBurst(from: edge)
        // Reuse the edge's own geometry length by adding a thin overlay cylinder
        // at the edge local origin (the parent orients Y along a->b).
        let cyl = SCNCylinder(radius: 0.10, height: 1.0)
        cyl.radialSegmentCount = 8
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.95)
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.blendMode = .add
        mat.transparencyMode = .aOne
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        cyl.firstMaterial = mat
        let node = SCNNode(geometry: cyl)
        node.name = "feedbackBurst"
        node.simdPosition = .zero
        node.renderingOrder = 90
        edge.addChildNode(node)
        let flash = SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.85, duration: 0.05),
            SCNAction.fadeOpacity(to: 0.0, duration: 0.30),
            SCNAction.removeFromParentNode()
        ])
        node.runAction(flash, forKey: "feedbackBurst")
    }

    /// An ambient ripple for a yield/pass: a slow expanding ring that fades,
    /// reading as a deliberate "step back" rather than an aggressive accent.
    private func attachYieldRipple(to host: SCNNode) {
        removeFeedbackBurst(from: host)
        let ring = SCNTorus(ringRadius: 0.22, pipeRadius: 0.016)
        let mat = SCNMaterial()
        mat.diffuse.contents = yieldColor
        mat.emission.contents = yieldColor.withAlphaComponent(0.7)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        ring.firstMaterial = mat
        let node = SCNNode(geometry: ring)
        node.name = "feedbackBurst"
        node.simdPosition = SIMD3<Float>(0, 0.10, 0)
        node.renderingOrder = 90
        host.addChildNode(node)
        let ripple = SCNAction.sequence([
            SCNAction.scale(to: 2.0, duration: 0.34),
            SCNAction.fadeOpacity(to: 0.0, duration: 0.22),
            SCNAction.removeFromParentNode()
        ])
        node.runAction(ripple, forKey: "feedbackBurst")
    }

    /// A rejected-action snapback: a quick lateral shake + red flash so the
    /// player reads the "no" on the target they were aiming at. Keyed under
    /// "feedbackBurst".
    private func attachSnapback(to host: SCNNode, color: NSColor) {
        removeFeedbackBurst(from: host)
        let ring = SCNTorus(ringRadius: 0.20, pipeRadius: 0.022)
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.95)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        ring.firstMaterial = mat
        let node = SCNNode(geometry: ring)
        node.name = "feedbackBurst"
        node.simdPosition = SIMD3<Float>(0, 0.12, 0)
        node.renderingOrder = 90
        host.addChildNode(node)
        let shake = SCNAction.sequence([
            SCNAction.moveBy(x: 0.06, y: 0, z: 0, duration: 0.05),
            SCNAction.moveBy(x: -0.12, y: 0, z: 0, duration: 0.07),
            SCNAction.moveBy(x: 0.06, y: 0, z: 0, duration: 0.05),
            SCNAction.fadeOpacity(to: 0.0, duration: 0.16),
            SCNAction.removeFromParentNode()
        ])
        node.runAction(shake, forKey: "feedbackBurst")
    }

    /// Remove any in-flight feedback burst child from a host node.
    private func removeFeedbackBurst(from host: SCNNode) {
        // SCNNode exposes a singular childNode(withName:recursively:); collect
        // matches by walking direct children so all in-flight bursts clear.
        var found: [SCNNode] = []
        for child in host.childNodes where child.name == "feedbackBurst" {
            found.append(child)
        }
        found.forEach { $0.removeFromParentNode() }
    }

    /// Attach (or replace) the persistent commitment glow on a target host.
    /// The glow is a soft colored ring that pulses while locked/resolving.
    private func attachCommitmentGlow(to host: SCNNode, player: Player, phase: BoardCommitmentGlow.Phase) {
        removeCommitmentGlow()
        let ring = SCNTorus(ringRadius: 0.42, pipeRadius: 0.024)
        let mat = SCNMaterial()
        let color = commitmentColor(for: player)
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(0.8)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        ring.firstMaterial = mat
        let node = SCNNode(geometry: ring)
        node.name = "commitmentGlow"
        node.simdPosition = SIMD3<Float>(0, 0.14, 0)
        node.renderingOrder = 80
        host.addChildNode(node)
        commitmentGlowNode = node
        if !reduceMotion {
            // A slower, steadier pulse than the selection ring so the locked-in
            // intent reads as "held" rather than "active cursor".
            let pulse = SCNAction.repeatForever(SCNAction.sequence([
                SCNAction.scale(by: 1.08, duration: 0.5),
                SCNAction.scale(by: 1.0 / 1.08, duration: 0.5)
            ]))
            node.runAction(pulse, forKey: "commitmentGlowPulse")
        }
        _ = phase
    }

    /// Fade the commitment glow out and remove it (exchange resolved).
    private func fadeOutCommitmentGlow() {
        guard let node = commitmentGlowNode else { return }
        node.removeAction(forKey: "commitmentGlowPulse")
        if reduceMotion {
            node.removeFromParentNode()
            commitmentGlowNode = nil
            return
        }
        let fade = SCNAction.sequence([
            SCNAction.fadeOpacity(to: 0.0, duration: 0.22),
            SCNAction.removeFromParentNode()
        ])
        node.runAction(fade)
        // Clear the reference immediately; the node self-removes when the
        // fade completes. A new glow will attach fresh on the next change.
        commitmentGlowNode = nil
    }

    /// Remove the commitment glow immediately (window cleared / scene rebuilt).
    private func removeCommitmentGlow() {
        commitmentGlowNode?.removeAction(forKey: "commitmentGlowPulse")
        commitmentGlowNode?.removeFromParentNode()
        commitmentGlowNode = nil
    }

    /// Accent color for a feedback pulse by player (P1 red, P2 orange).
    private func feedbackColor(for pulse: BoardFeedbackPulse) -> NSColor {
        pulse.player == .player1 ? player1Accent : player2Accent
    }

    /// Commitment glow color by player.
    private func commitmentColor(for player: Player) -> NSColor {
        player == .player1 ? player1Accent : player2Accent
    }

    private var player1Accent: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.18, blue: 0.10, alpha: 1)
    }
    private var player2Accent: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.55, blue: 0.14, alpha: 1)
    }
    private var severColor: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.12, blue: 0.20, alpha: 1)
    }
    private var rejectColor: NSColor {
        NSColor(calibratedRed: 1.0, green: 0.10, blue: 0.10, alpha: 1)
    }
    private var yieldColor: NSColor {
        NSColor(calibratedRed: 0.62, green: 0.52, blue: 0.78, alpha: 1)
    }

    // MARK: - Layout

    private struct UprightLayout {
        let panelWidth: CGFloat
        let panelHeight: CGFloat
        let centerPlateau: CGFloat
        let depthSpan: CGFloat
        let planeZ: (Int) -> CGFloat
        let nodePosition: (NodeDef) -> SIMD3<Float>
    }

    private func uprightLayout(for board: BoardDefinition) -> UprightLayout {
        let scene = BoardSceneLayout.compute(
            for: board,
            gridUnit: Float(gridUnit),
            layerSpacing: Float(layerSpacing),
            panelMargin: Float(panelMargin))
        currentSceneLayout = scene
        let planeZFn: (Int) -> CGFloat = { p in CGFloat(scene.planeZ[p] ?? 0) }
        let nodePos: (NodeDef) -> SIMD3<Float> = { node in
            scene.nodePosition[node.id] ?? SIMD3<Float>(0, 0, 0)
        }
        return UprightLayout(panelWidth: CGFloat(scene.panelWidth),
                             panelHeight: CGFloat(scene.panelHeight),
                             centerPlateau: CGFloat(board.plateaus.count - 1) * 0.5,
                             depthSpan: CGFloat(scene.depthSpan),
                             planeZ: planeZFn, nodePosition: nodePos)
    }

    /// Depth-aware presentation factor in [0, 1] for a plateau. Returns 1 for
    /// the nearest plateau to the fixed camera (highest Z) and 0 for the
    /// farthest. Used to fade far planes slightly more than near ones so the
    /// stack reads as receding into the projector haze without hiding nodes.
    private func depthFactor(forPlateau index: Int) -> CGFloat {
        guard let layout = currentSceneLayout else { return 1 }
        let zs = layout.planeZ.values.sorted()
        guard let lo = zs.first, let hi = zs.last, hi > lo else { return 1 }
        let z = layout.planeZ[index] ?? lo
        // Camera looks from +Z toward -Z, so higher Z = nearer.
        return CGFloat((z - lo) / (hi - lo))
    }

    // MARK: - Lighting

    private func addLighting(to root: SCNNode) {
        let ambient = SCNNode()
        let ambientLight = SCNLight()
        ambientLight.type = .ambient
        ambientLight.color = NSColor(calibratedRed: 0.32, green: 0.30, blue: 0.40, alpha: 1)
        ambientLight.intensity = 420
        ambient.light = ambientLight
        root.addChildNode(ambient)

        let key = SCNNode()
        let keyLight = SCNLight()
        keyLight.type = .directional
        keyLight.color = NSColor(calibratedRed: 0.84, green: 0.90, blue: 0.90, alpha: 1)
        keyLight.intensity = 680
        key.simdEulerAngles = SIMD3<Float>(-.pi * 0.22, .pi * 0.12, 0)
        key.light = keyLight
        root.addChildNode(key)

        let fill = SCNNode()
        let fillLight = SCNLight()
        fillLight.type = .omni
        fillLight.color = NSColor(calibratedRed: 0.4, green: 0.8, blue: 0.7, alpha: 1)
        fillLight.intensity = 180
        fill.simdPosition = SIMD3<Float>(-6, -2, 8)
        fill.light = fillLight
        root.addChildNode(fill)

        let rim = SCNNode()
        let rimLight = SCNLight()
        rimLight.type = .omni
        rimLight.color = NSColor(calibratedRed: 0.30, green: 0.75, blue: 0.85, alpha: 1)
        rimLight.intensity = 480
        rim.simdPosition = SIMD3<Float>(6, 4, -6)
        rim.light = rimLight
        root.addChildNode(rim)
    }

    // MARK: - Upright translucent panels (large static layers)

    private func addUprightPanel(to root: SCNNode, plateau: PlateauDef, layout: UprightLayout) {
        let w = layout.panelWidth
        let h = layout.panelHeight
        let panel = SCNPlane(width: w, height: h)
        let mat = SCNMaterial()
        mat.diffuse.contents = panelTint(for: plateau.index)
        // Depth-aware transparency: near planes read more solidly, far planes
        // recede into the projector haze. Segment 9: raised from 0.030..0.058
        // to 0.08..0.14 so the upright panels read as denser projected light
        // (matching the reference stills' higher hologram density) and thin
        // line structure becomes a smaller fraction of the nonblank area.
        let depth = depthFactor(forPlateau: plateau.index)
        mat.transparency = 0.08 + depth * 0.060
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false
        panel.firstMaterial = mat
        let node = SCNNode(geometry: panel)
        node.simdPosition = SIMD3<Float>(0, 0, Float(layout.planeZ(plateau.index)))
        node.name = "panel-\(plateau.index)"
        root.addChildNode(node)

        // A faint border frame around the panel.
        let frame = frameBox(width: w, height: h, thickness: 0.04,
                             color: NSColor(calibratedRed: 0.55, green: 0.78, blue: 0.72, alpha: 0.55))
        let frameNode = SCNNode(geometry: frame)
        frameNode.position = node.position
        root.addChildNode(frameNode)
    }

    private func panelTint(for index: Int) -> NSColor {
        // Each upright plane carries a slightly different cool tint so the
        // overlapping translucent layers read as distinct stratified slabs.
        // Segment 9: brightened the tints (0.18-0.24 -> 0.28-0.36) so the
        // panels read as luminous projected light, not dark glass. Brighter
        // panels reduce the contrast between thin grid/edge lines and the
        // background, lowering the gradient-based grid-occupancy metric
        // toward the reference stills' soft, diffuse hologram look.
        switch index % 3 {
        case 0: return NSColor(calibratedRed: 0.28, green: 0.34, blue: 0.48, alpha: 1)
        case 1: return NSColor(calibratedRed: 0.30, green: 0.40, blue: 0.44, alpha: 1)
        default: return NSColor(calibratedRed: 0.36, green: 0.34, blue: 0.46, alpha: 1)
        }
    }

    // MARK: - Concentric rectilinear outlines (green/teal nesting inward)

    private func addConcentricOutlines(to root: SCNNode, plateau: PlateauDef, layout: UprightLayout) {
        let z = Float(layout.planeZ(plateau.index)) + 0.02
        let maxW = layout.panelWidth - panelMargin
        let maxH = layout.panelHeight - panelMargin
        // Segment 9: reduced from 7 to 2 rings. The reference stills show a
        // sparse hologram with few nesting outlines, not a dense grid of rings.
        // Fewer, bolder outlines read as cleaner projected light.
        let rings = 2
        for i in 0..<rings {
            let frac = CGFloat(i + 1) / CGFloat(rings)
            let w = maxW * (1.0 - frac * 0.62)
            let h = maxH * (1.0 - frac * 0.62)
            let alpha = 0.72 - CGFloat(i) * 0.12
            let color = NSColor(calibratedRed: 0.22 + CGFloat(i) * 0.06,
                                green: 0.83 - CGFloat(i) * 0.04,
                                blue: 0.55 + CGFloat(i) * 0.03, alpha: alpha)
            let outline = frameBox(width: w, height: h, thickness: 0.025 + CGFloat(i) * 0.004,
                                   color: color)
            let node = SCNNode(geometry: outline)
            node.simdPosition = SIMD3<Float>(0, 0, z + Float(i) * 0.01)
            root.addChildNode(node)
        }
    }

    // MARK: - Colored translucent fields (lavender / chartreuse / yellow)

    private func addColoredFields(to root: SCNNode, plateau: PlateauDef, layout: UprightLayout) {
        let z = Float(layout.planeZ(plateau.index)) + 0.04
        let w = layout.panelWidth - panelMargin
        let h = layout.panelHeight - panelMargin
        let fields: [(CGFloat, CGFloat, CGFloat, CGFloat, NSColor)] = [
            // (offsetX, offsetY, widthFrac, heightFrac, color)
            // Segment 9: raised field alphas slightly (0.16/0.13/0.11 ->
            // 0.22/0.18/0.15) for denser translucent regions matching the
            // reference stills' overlapping colored panels.
            (-w * 0.18, h * 0.03, 0.62, 0.95,
             NSColor(calibratedRed: 0.70, green: 0.60, blue: 0.88, alpha: 0.22)), // lavender
            (w * 0.16, -h * 0.02, 0.54, 0.90,
             NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.40, alpha: 0.18)), // chartreuse
            (0, h * 0.15, 0.46, 0.64,
             NSColor(calibratedRed: 0.92, green: 0.86, blue: 0.32, alpha: 0.15))  // yellow
        ]
        for (ox, oy, wf, hf, color) in fields {
            let fw = w * wf
            let fh = h * hf
            let plane = SCNPlane(width: fw, height: fh)
            let mat = SCNMaterial()
            mat.diffuse.contents = color.withAlphaComponent(1)
            // Depth-aware: far fields fade more than near fields.
            let depth = depthFactor(forPlateau: plateau.index)
            let baseAlpha = min(0.25, color.alphaComponent * 1.5)
            mat.transparency = baseAlpha * (0.55 + depth * 0.45)
            mat.lightingModel = .constant
            mat.isDoubleSided = true
            mat.transparencyMode = .aOne
            mat.blendMode = .alpha
            mat.writesToDepthBuffer = false
            plane.firstMaterial = mat
            let node = SCNNode(geometry: plane)
            node.simdPosition = SIMD3<Float>(Float(ox), Float(oy), z + 0.01)
            root.addChildNode(node)
        }
    }

    // MARK: - Gold grid lines

    private func addGridLines(to root: SCNNode, board: BoardDefinition, plateau: PlateauDef,
                              layout: UprightLayout) {
        let z = Float(layout.planeZ(plateau.index)) + 0.05
        let gold = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.26, alpha: 0.42)
        // Depth-aware: far grids are slightly dimmer so near plateaus read as
        // the active tactical foreground. Segment 9: lowered grid line alpha
        // (0.28+depth*0.18 -> 0.15+depth*0.10) so the gold circuitry reads as
        // faint traced paths, not sharp thin lines that dominate the gradient
        // structure. The reference stills show sparse line density.
        let depth = depthFactor(forPlateau: plateau.index)
        let gridColor = gold.withAlphaComponent(CGFloat(0.08 + depth * 0.06))
        let nodes = board.nodes.filter { $0.plateau == plateau.index }
        let rows = Set(nodes.map(\.y)).sorted()
        let cols = Set(nodes.map(\.x)).sorted()
        for row in rows {
            let rowNodes = nodes.filter { $0.y == row }.sorted { $0.x < $1.x }
            guard let first = rowNodes.first, let last = rowNodes.last else { continue }
            let a = layout.nodePosition(first)
            let b = layout.nodePosition(last)
            let line = addLine(from: SIMD3<Float>(a.x, a.y, z), to: SIMD3<Float>(b.x, b.y, z),
                    radius: 0.012, color: gridColor, to: root)
            attachGridEnergyPulse(to: line)
        }
        for col in cols {
            let colNodes = nodes.filter { $0.x == col }.sorted { $0.y < $1.y }
            guard let first = colNodes.first, let last = colNodes.last else { continue }
            let a = layout.nodePosition(first)
            let b = layout.nodePosition(last)
            let line = addLine(from: SIMD3<Float>(a.x, a.y, z), to: SIMD3<Float>(b.x, b.y, z),
                    radius: 0.012, color: gridColor, to: root)
            attachGridEnergyPulse(to: line)
        }
    }

    /// Attaches a slow, restrained grid-energy pulse to a grid-line node. The
    /// pulse gently modulates opacity so the gold circuitry reads as carrying
    /// a low travelling current. Gated off under reduceMotion.
    private func attachGridEnergyPulse(to node: SCNNode) {
        gridLineNodes.append(node)
        guard !reduceMotion else { return }
        // A slow breathing of the opacity channel — never bright enough to
        // compete with tokens or territory.
        let pulse = SCNAction.repeatForever(SCNAction.sequence([
            SCNAction.fadeOpacity(by: 0.18, duration: 1.8),
            SCNAction.fadeOpacity(by: -0.18, duration: 1.8)
        ]))
        pulse.timingMode = .easeInEaseOut
        node.runAction(pulse, forKey: "gridEnergy")
    }

    // MARK: - Territory faces (state-dependent colored regions)

    /// Renders controlled/sealed faces as translucent colored polygons on the
    /// plateau planes. Each face with a controller or sealedBy gets a fan-
    /// triangulated polygon in the controller's color. Irregular faces (5/6/8
    /// nodes) and cross-plateau sectors (nodes on different Z planes) are
    /// handled by the same convex-fan triangulation.
    private func addTerritoryFaces(to root: SCNNode, board: BoardDefinition,
                                   state: GameState, layout: UprightLayout) {
        for face in board.faces {
            let fs = state.faces[face.id] ?? FaceState()
            guard let controller = fs.controller ?? fs.sealedBy else { continue }
            guard let node = makeTerritoryFaceNode(face: face, board: board,
                                                    controller: controller,
                                                    sealed: fs.sealedBy != nil,
                                                    layout: layout) else { continue }
            root.addChildNode(node)
            faceNodes[face.id] = node
        }
    }

    /// Refreshes territory face visibility/color on state change without
    /// rebuilding geometry. Faces that newly gain/lose a controller are
    /// added/removed; faces that changed controller get their color updated.
    /// A change in sealed state rebuilds the node so the bloom/scanline
    /// presentation layer is added or removed correctly.
    private func updateTerritoryFaces(board: BoardDefinition, state: GameState) {
        guard let layout = currentLayout else { return }
        for face in board.faces {
            let fs = state.faces[face.id] ?? FaceState()
            let controller = fs.controller ?? fs.sealedBy
            let sealedNow = fs.sealedBy != nil
            if let existing = faceNodes[face.id] {
                // If the sealed state changed, rebuild so bloom/scanline match.
                let hasScanline = existing.childNode(withName: "scanline", recursively: false) != nil
                if hasScanline != sealedNow, let controller {
                    existing.removeFromParentNode()
                    faceNodes.removeValue(forKey: face.id)
                    if let node = makeTerritoryFaceNode(face: face, board: board,
                                                        controller: controller,
                                                        sealed: sealedNow,
                                                        layout: layout) {
                        scnView.scene?.rootNode.addChildNode(node)
                        faceNodes[face.id] = node
                        attachStatePulse(to: node)
                    }
                    continue
                }
                if let controller {
                    // Update color/alpha in place.
                    let color = territoryColor(for: controller)
                    let alpha: Float = sealedNow ? 0.25 : 0.12
                    existing.geometry?.firstMaterial?.diffuse.contents = color
                    existing.geometry?.firstMaterial?.transparency = CGFloat(alpha)
                    existing.geometry?.firstMaterial?.emission.contents =
                        color.withAlphaComponent(min(1, CGFloat(alpha) * 1.6))
                    existing.isHidden = false
                    // State-change feedback: pulse when the controller changes.
                    if previousTerritoryControllers[face.id] != controller {
                        attachStatePulse(to: existing)
                    }
                } else {
                    // Lost control — remove.
                    existing.removeFromParentNode()
                    faceNodes.removeValue(forKey: face.id)
                }
            } else if let controller {
                // Newly controlled — add.
                if let node = makeTerritoryFaceNode(face: face, board: board,
                                                    controller: controller,
                                                    sealed: sealedNow,
                                                    layout: layout) {
                    scnView.scene?.rootNode.addChildNode(node)
                    faceNodes[face.id] = node
                    attachStatePulse(to: node)
                }
            }
        }
    }

    /// Builds a single territory face node: a fan-triangulated convex polygon
    /// from the face's ordered corner nodes, rendered in the controller's color
    /// at low alpha. Returns nil if the face has fewer than 3 corners. Sealed
    /// faces receive an additive bloom layer and a slow scanline shimmer
    /// (gated on reduceMotion) per the hologram visual direction.
    private func makeTerritoryFaceNode(face: FaceDef, board: BoardDefinition,
                                       controller: Owner, sealed: Bool,
                                       layout: UprightLayout) -> SCNNode? {
        let cornerIds = orderedFaceNodes(face, board: board)
        guard cornerIds.count >= 3 else { return nil }
        let corners = cornerIds.compactMap { board.nodeMap[$0] }
        guard corners.count == cornerIds.count else { return nil }
        let positions = corners.map { layout.nodePosition($0) }
        guard positions.count >= 3 else { return nil }

        let color = territoryColor(for: controller)
        let alpha: CGFloat = sealed ? 0.25 : 0.12
        let geo = buildFacePolygonGeometry(positions: positions, color: color, alpha: alpha)
        let node = SCNNode(geometry: geo)
        node.name = "territory:\(face.id)"
        node.renderingOrder = -1  // behind edges and tokens

        // Projection bloom: a second, wider additive layer in the controller
        // color gives sealed faces a soft projected halo. Only sealed faces
        // bloom — controlled-but-unsealed faces stay restrained so the board
        // reads as sparse projected light, not uniform neon.
        if sealed {
            addTerritoryBloom(to: node, positions: positions, color: color)
            addTerritoryScanline(to: node, positions: positions, color: color)
        }
        return node
    }

    /// Adds a layered additive bloom halo to a sealed territory face. The
    /// bloom is a second fan-triangulated polygon scaled outward from the
    /// face centroid, blended additively at low alpha so it reads as a soft
    /// projected glow rather than a solid fill.
    private func addTerritoryBloom(to node: SCNNode, positions: [SIMD3<Float>],
                                   color: NSColor) {
        let centroid = positions.reduce(SIMD3<Float>.zero) { $0 + $1 } / Float(positions.count)
        let scaled = positions.map { centroid + ($0 - centroid) * 1.06 }
        let geo = buildFacePolygonGeometry(positions: scaled, color: color, alpha: 0.10)
        // Switch the bloom material to additive blend for the glow look.
        geo.firstMaterial?.blendMode = .add
        geo.firstMaterial?.transparency = 0.10
        geo.firstMaterial?.emission.contents = color.withAlphaComponent(0.5)
        let bloom = SCNNode(geometry: geo)
        bloom.name = "bloom"
        bloom.renderingOrder = -2  // behind the base face
        node.addChildNode(bloom)
    }

    /// Adds a slow vertical scanline shimmer to a sealed territory face. A
    /// thin additive bar travels along the face's local Y extent, reading as
    /// the "restrained scanline shimmer" the visual direction calls for. The
    /// bar is parented to the face node and animated via SCNAction, gated off
    /// under reduceMotion (the bar is still created so the scene graph is
    /// testable, but it stays hidden and static).
    private func addTerritoryScanline(to node: SCNNode, positions: [SIMD3<Float>],
                                      color: NSColor) {
        let ys = positions.map { $0.y }
        guard let yLo = ys.min(), let yHi = ys.max(), yHi > yLo else { return }
        let xs = positions.map { $0.x }
        let xLo = (xs.min() ?? 0) - 0.15
        let xHi = (xs.max() ?? 0) + 0.15
        let z = (positions.map { $0.z }.max() ?? 0) + 0.02
        let barHeight: Float = 0.18
        let bar = SCNPlane(width: CGFloat(xHi - xLo), height: CGFloat(barHeight))
        let mat = SCNMaterial()
        mat.diffuse.contents = color.withAlphaComponent(0.5)
        mat.emission.contents = color.withAlphaComponent(0.8)
        mat.transparency = 0.32
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        mat.blendMode = .add
        mat.writesToDepthBuffer = false
        bar.firstMaterial = mat
        let barNode = SCNNode(geometry: bar)
        barNode.name = "scanline"
        let centerX = (xLo + xHi) * 0.5
        barNode.simdPosition = SIMD3<Float>(centerX, yLo, z)
        barNode.renderingOrder = -1
        if reduceMotion {
            barNode.isHidden = true
        } else {
            // Travel the bar between the face's Y extents, keeping X/Z fixed.
            let low = SCNVector3(CGFloat(centerX), CGFloat(yLo), CGFloat(z))
            let high = SCNVector3(CGFloat(centerX), CGFloat(yHi), CGFloat(z))
            let travel = SCNAction.repeatForever(SCNAction.sequence([
                SCNAction.move(to: high, duration: 2.6),
                SCNAction.move(to: low, duration: 2.6)
            ]))
            barNode.runAction(travel, forKey: "scanlineTravel")
        }
        node.addChildNode(barNode)
    }

    /// Walks a face's ordered boundary edges to extract the ordered node cycle.
    /// The first edge sets the orientation (u -> v); each subsequent edge must
    /// share the current node. Returns [] if the walk fails (should not happen
    /// for validated boards).
    private func orderedFaceNodes(_ face: FaceDef, board: BoardDefinition) -> [String] {
        guard face.boundary.count >= 3 else { return [] }
        guard let first = board.edgeMap[face.boundary[0]] else { return [] }
        var cycle: [String] = [first.u, first.v]
        var prev = first.v
        for i in 1..<face.boundary.count {
            guard let e = board.edgeMap[face.boundary[i]] else { return [] }
            let next = (e.u == prev) ? e.v : (e.v == prev ? e.u : nil)
            guard let n = next else { return [] }
            cycle.append(n)
            prev = n
        }
        // Drop the closing duplicate (last == first).
        if cycle.last == cycle.first { cycle.removeLast() }
        return cycle
    }

    /// Builds a custom SCNGeometry from a convex polygon by fan-triangulating
    /// from the first vertex: triangles (0, i, i+1) for i in 1..<count-1.
    private func buildFacePolygonGeometry(positions: [SIMD3<Float>],
                                          color: NSColor, alpha: CGFloat) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var indices: [Int32] = []
        for p in positions {
            vertices.append(SCNVector3(p.x, p.y, p.z))
        }
        for i in 1..<(positions.count - 1) {
            indices.append(contentsOf: [0, Int32(i), Int32(i + 1)])
        }
        let src = SCNGeometrySource(vertices: vertices)
        let elem = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(min(1, alpha * 1.6))
        mat.transparency = alpha
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.transparencyMode = .aOne
        mat.blendMode = .alpha
        mat.writesToDepthBuffer = false
        geo.firstMaterial = mat
        return geo
    }

    /// Territory fill color for a controller. Distinct from token color: the
    /// fill is a translucent wash of the player's identity color, matching the
    /// episode's "change the color of the panels to the assigned color."
    private func territoryColor(for owner: Owner) -> NSColor {
        switch owner {
        case .player1:
            return NSColor(calibratedRed: 0.92, green: 0.10, blue: 0.06, alpha: 1)
        case .player2:
            return NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.10, alpha: 1)
        case .severed:
            return NSColor(calibratedRed: 0.42, green: 0.04, blue: 0.06, alpha: 1)
        case .neutral:
            return NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.26, alpha: 1)
        }
    }

    // MARK: - Edges

    private func addEdges(to root: SCNNode, board: BoardDefinition, state: GameState,
                          layout: UprightLayout) {
        for edge in board.edges {
            guard let u = board.nodeMap[edge.u], let v = board.nodeMap[edge.v] else { continue }
            let a = layout.nodePosition(u)
            let b = layout.nodePosition(v)
            let es = state.edges[edge.id] ?? EdgeState()
            let color = edgeColor(for: es.owner, kind: edge.kind)
            let radius: CGFloat = edge.kind == .conduit ? 0.05 : 0.032
            let rendered = addLine(from: a, to: b, radius: radius, color: color, to: root)
            rendered.name = "edge:\(edge.id)"
            // Segment 9: reduced non-severed edge opacity (1.0 -> 0.60) to
            // soften the contrast between topology lines and the panel
            // background. The reference stills show soft projected light, not
            // sharp wireframe lines. Edges remain clearly visible at 0.60.
            rendered.opacity = es.severed ? 0.16 : 0.60
            edgeNodes[edge.id] = rendered
            // Projection bloom: a wider additive cylinder gives owned and
            // conduit edges a soft projected glow. Severed edges stay dim.
            if !es.severed {
                addEdgeBloom(to: rendered, from: a, to: b,
                             radius: radius, color: color)
            }
        }
    }

    /// Adds a layered additive bloom halo to an edge: a second wider cylinder
    /// blended additively at low alpha. The bloom is parented to the edge node
    /// at its local origin so it inherits the edge's position/orientation and
    /// aligns perfectly along the same axis.
    private func addEdgeBloom(to edge: SCNNode, from a: SIMD3<Float>, to b: SIMD3<Float>,
                              radius: CGFloat, color: NSColor) {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let length = max((dx*dx + dy*dy + dz*dz).squareRoot(), 0.001)
        // Segment 9: widened the bloom (2.4x -> 3.8x radius) and softened it
        // (alpha 0.16 -> 0.07) so it reads as a diffuse projected glow rather
        // than a sharp second line. Lower contrast at the bloom edge reduces
        // the gradient-based grid-occupancy metric toward the reference's soft
        // hologram look.
        let bloomRadius = radius * 3.8
        let cyl = SCNCylinder(radius: bloomRadius, height: CGFloat(length))
        cyl.radialSegmentCount = 8
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(min(1, color.alphaComponent * 1.4))
        mat.transparency = 0.07
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.blendMode = .add
        mat.transparencyMode = .aOne
        mat.writesToDepthBuffer = false
        cyl.firstMaterial = mat
        let bloom = SCNNode(geometry: cyl)
        bloom.name = "bloom"
        // Local origin = edge center; the parent edge already orients its Y
        // axis along a->b, so a centered child cylinder aligns automatically.
        bloom.simdPosition = SIMD3<Float>.zero
        bloom.renderingOrder = -1
        edge.addChildNode(bloom)
    }

    // MARK: - Node ring tokens (red/yellow, selectable)

    private func addNodeTokens(to root: SCNNode, board: BoardDefinition, state: GameState,
                               layout: UprightLayout) {
        for node in board.nodes {
            let pos = layout.nodePosition(node)
            let ns = state.nodes[node.id] ?? NodeState()
            let ringRadius: CGFloat = node.kind == .anchor ? 0.26 : (node.kind == .conduit ? 0.20 : 0.17)
            let tubeRadius: CGFloat = node.kind == .anchor ? 0.042 : 0.026
            let torus = SCNTorus(ringRadius: ringRadius, pipeRadius: tubeRadius)
            let mat = SCNMaterial()
            mat.diffuse.contents = tokenColor(for: ns.owner)
            mat.emission.contents = tokenEmission(for: ns.owner, influence: ns.influence)
            mat.specular.contents = NSColor.white
            mat.shininess = 0.8
            mat.lightingModel = .constant
            torus.firstMaterial = mat
            let token = SCNNode(geometry: torus)
            // SCNTorus lies in the XZ plane (ring around Y); rotate to face +Z.
            token.simdEulerAngles = SIMD3<Float>(.pi * 0.5, 0, 0)
            token.simdPosition = SIMD3<Float>(pos.x, pos.y, pos.z + 0.08)
            token.name = node.id
            root.addChildNode(token)
            nodeTokens[node.id] = token

            // A small inner disc gives the token a solid readable core.
            let disc = SCNCylinder(radius: ringRadius * 0.55, height: 0.04)
            let discMat = SCNMaterial()
            discMat.diffuse.contents = tokenColor(for: ns.owner)
            discMat.emission.contents = tokenEmission(for: ns.owner, influence: ns.influence).withAlphaComponent(0.4)
            discMat.lightingModel = .constant
            disc.firstMaterial = discMat
            let discNode = SCNNode(geometry: disc)
            // Children inherit the token's rotation and position. Applying
            // world coordinates twice scattered these discs outside the board.
            discNode.simdPosition = SIMD3<Float>(0, 0.04, 0)
            discNode.name = "core"
            discNode.isHidden = ns.owner == .neutral
            token.addChildNode(discNode)

            // Projection bloom: a flattened additive sphere behind the ring
            // gives owned tokens a soft projected halo. Neutral tokens stay
            // un-bloomed so the board reads as sparse projected light.
            if ns.owner != .neutral {
                addTokenBloom(to: token, radius: ringRadius,
                              color: tokenEmission(for: ns.owner, influence: ns.influence))
            }
        }
    }

    /// Adds a layered additive bloom halo to a token: a flattened sphere
    /// parented to the token at its local origin, blended additively at low
    /// alpha. The bloom inherits the token's rotation so it stays centered on
    /// the ring facing the camera.
    private func addTokenBloom(to token: SCNNode, radius: CGFloat, color: NSColor) {
        let bloom = SCNSphere(radius: radius * 1.55)
        bloom.segmentCount = 12
        let mat = SCNMaterial()
        mat.diffuse.contents = color.withAlphaComponent(0.5)
        mat.emission.contents = color.withAlphaComponent(0.8)
        mat.transparency = 0.22
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        mat.blendMode = .add
        mat.transparencyMode = .aOne
        mat.writesToDepthBuffer = false
        bloom.firstMaterial = mat
        let bloomNode = SCNNode(geometry: bloom)
        bloomNode.name = "bloom"
        bloomNode.simdPosition = SIMD3<Float>.zero
        bloomNode.renderingOrder = -1
        token.addChildNode(bloomNode)
    }

    private func updateSelectionRing() {
        selectionRing?.removeFromParentNode()
        selectionRing = nil
        guard let id = selectedNodeId, let token = nodeTokens[id],
              let scene = scnView.scene else { return }
        let ring = SCNTorus(ringRadius: 0.38, pipeRadius: 0.028)
        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor(calibratedRed: 0.5, green: 1, blue: 0.9, alpha: 1)
        mat.emission.contents = NSColor(calibratedRed: 0.3, green: 0.8, blue: 0.7, alpha: 1)
        mat.lightingModel = .constant
        mat.readsFromDepthBuffer = false
        mat.writesToDepthBuffer = false
        ring.firstMaterial = mat
        let ringNode = SCNNode(geometry: ring)
        ringNode.simdPosition = SIMD3<Float>(0, 0.10, 0)
        ringNode.renderingOrder = 100
        if !reduceMotion {
            let pulse = SCNAction.repeatForever(SCNAction.sequence([
                SCNAction.scale(by: 1.12, duration: 0.6),
                SCNAction.scale(by: 1.0 / 1.12, duration: 0.6)
            ]))
            ringNode.runAction(pulse)
        }
        token.addChildNode(ringNode)
        selectionRing = ringNode
        _ = scene // keep scene reference used
    }

    // MARK: - Projector table (pale perforated beveled tiers)

    private func addProjectorTable(to root: SCNNode, planeWidth: CGFloat, planeHeight: CGFloat) {
        // Segment 9: raised the table from -0.95 to -0.55 below the panel
        // bottom. The smaller vertical gap lets the camera frame tighter,
        // filling more of the viewport width (the reference stills fill the
        // full frame width). The table still sits clearly beneath the planes.
        let baseY = -planeHeight * 0.5 - 0.55
        let depth = max(4.4, CGFloat(currentSceneLayout?.depthSpan ?? 4.8) + 1.1)
        let table = SCNNode()
        table.name = "projector-table"
        table.simdPosition = SIMD3<Float>(0, Float(baseY), 0)
        for index in 0..<3 {
            let width = planeWidth * 1.22 - CGFloat(index) * 0.24
            let length = depth + 0.5 - CGFloat(index) * 0.18
            let box = SCNBox(width: width, height: 0.21, length: length, chamferRadius: 0.10)
            let material = SCNMaterial()
            material.lightingModel = .physicallyBased
            material.diffuse.contents = NSColor(calibratedRed: 0.49, green: 0.55, blue: 0.53, alpha: 1)
            material.metalness.contents = 0.2
            material.roughness.contents = 0.48
            box.firstMaterial = material
            let tier = SCNNode(geometry: box)
            tier.simdPosition = SIMD3<Float>(0, Float(index) * 0.255, 0)
            table.addChildNode(tier)
        }

        // One original procedural texture gives the projector thousands of
        // luminous perforations without thousands of individual draw calls.
        let surface = SCNPlane(width: planeWidth * 1.04, height: depth * 0.88)
        let surfaceMaterial = SCNMaterial()
        surfaceMaterial.lightingModel = .constant
        surfaceMaterial.diffuse.contents = projectorPattern()
        surfaceMaterial.isDoubleSided = true
        surface.firstMaterial = surfaceMaterial
        let surfaceNode = SCNNode(geometry: surface)
        surfaceNode.name = "perforated-emitter"
        surfaceNode.simdEulerAngles = SIMD3<Float>(-.pi / 2, 0, 0)
        surfaceNode.simdPosition = SIMD3<Float>(0, 0.63, 0)
        table.addChildNode(surfaceNode)
        root.addChildNode(table)
    }

    private func projectorPattern() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 640), flipped: false) { rectangle in
            NSColor(calibratedRed: 0.08, green: 0.13, blue: 0.13, alpha: 1).setFill()
            rectangle.fill()
            for row in 0..<40 {
                for column in 0..<64 {
                    let x = CGFloat(column) * 16 + (row.isMultiple(of: 2) ? 2 : 10)
                    let y = CGFloat(row) * 16 + 2
                    let brightness: CGFloat = (row + column).isMultiple(of: 7) ? 0.86 : 0.65
                    NSColor(calibratedRed: brightness * 0.78, green: brightness,
                            blue: brightness * 0.87, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 10, height: 8)).fill()
                }
            }
            return true
        }
    }

    // MARK: - Five-finger sensor arrays and original blue interface cables

    private func addSensorRigs(to root: SCNNode, planeWidth: CGFloat, planeHeight: CGFloat) {
        let depth = max(4.4, CGFloat(currentSceneLayout?.depthSpan ?? 4.8) + 1.1)
        for side in [Float(-1), Float(1)] {
            for finger in 0..<5 {
                let spread = Float(finger - 2)
                let position = SIMD3<Float>(
                    side * (Float(planeWidth) * 0.54 + 0.55 + abs(spread) * 0.10),
                    -Float(planeHeight) * 0.5 + 0.30 + (2 - abs(spread)) * 0.20,
                    Float(depth) * 0.5 + 0.3 + spread * 0.29
                )
                let capsule = SCNCapsule(capRadius: 0.11, height: 0.62)
                capsule.radialSegmentCount = 12
                let material = SCNMaterial()
                material.lightingModel = .physicallyBased
                // Segment 9: brightened the sensor capsules (0.40/0.48/0.50 ->
                // 0.52/0.60/0.62) and reduced metalness (0.85 -> 0.65) so they
                // register as visible content at the frame edges, helping the
                // render fill the viewport width like the reference stills.
                material.diffuse.contents = NSColor(calibratedRed: 0.52, green: 0.60, blue: 0.62, alpha: 1)
                material.metalness.contents = 0.65
                material.roughness.contents = 0.30
                capsule.firstMaterial = material
                let sensor = SCNNode(geometry: capsule)
                sensor.name = "sensor-\(side)-\(finger)"
                sensor.simdPosition = position
                sensor.simdEulerAngles = SIMD3<Float>(.pi * 0.23, 0, side * -.pi * 0.16)
                root.addChildNode(sensor)

                let indicator = SCNSphere(radius: 0.025)
                let light = SCNMaterial()
                light.lightingModel = .constant
                light.diffuse.contents = NSColor(calibratedRed: 0.38, green: 1, blue: 0.59, alpha: 1)
                indicator.firstMaterial = light
                let indicatorNode = SCNNode(geometry: indicator)
                indicatorNode.simdPosition = SIMD3<Float>(0, 0.12, 0.10)
                sensor.addChildNode(indicatorNode)

                let end = SIMD3<Float>(side * Float(planeWidth) * 0.35,
                                      -Float(planeHeight) * 0.5 - 0.22,
                                      Float(depth) * 0.15 + spread * 0.19)
                let control = (position + end) * 0.5 + SIMD3<Float>(side * 0.28, 0.42, 0.25)
                var previous = position - SIMD3<Float>(0, 0.18, 0)
                // Segment 9: reduced cable segments from 16 to 5. The reference
                // stills show sparse line structure; fewer cable segments read
                // as cleaner trailing wires without losing the cable silhouette.
                for segment in 1...5 {
                    let t = Float(segment) / 5
                    let point = (1-t)*(1-t)*position + 2*(1-t)*t*control + t*t*end
                    addLine(from: previous, to: point, radius: 0.015,
                            color: NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.72, alpha: 0.80),
                            to: root)
                    previous = point
                }
            }
        }
    }

    // MARK: - Fixed camera

    private func installFixedCamera(layout: UprightLayout? = nil) {
        let cameraNode = SCNNode()
        cameraNode.name = "board-camera"
        let camera = SCNCamera()
        camera.fieldOfView = 48
        camera.projectionDirection = .vertical
        camera.zNear = 0.1
        camera.zFar = 200
        cameraNode.camera = camera
        // Fixed slightly elevated front view — no pivot/orbit. The initial
        // distance is a sane default; reframeCamera() adjusts it to the actual
        // viewport aspect once layout runs.
        let depth = layout.map { $0.depthSpan } ?? 8
        let dist = max(14, Float(depth) * 2.4)
        cameraNode.simdPosition = SIMD3<Float>(0, 3.2, dist)
        cameraNode.simdEulerAngles = SIMD3<Float>(-.pi * 0.10, 0, 0)
        if let scene = scnView.scene {
            scene.rootNode.addChildNode(cameraNode)
            scnView.pointOfView = cameraNode
        }
    }

    // MARK: - Geometry helpers

    /// Builds a rectangular wireframe as a single SCNGeometry of 8 thin boxes
    /// (4 edges, each made of a thin box). Returns a geometry suitable for a
    /// node placed at the panel center.
    private func frameBox(width: CGFloat, height: CGFloat, thickness: CGFloat,
                          color: NSColor) -> SCNGeometry {
        let w = width
        let h = height
        let t = thickness
        var sources: [SCNVector3] = []
        var indices: [Int32] = []
        // 4 bars: top, bottom, left, right. Each bar = a box approximated by 8 verts.
        func bar(_ cx: Float, _ cy: Float, _ bw: Float, _ bh: Float) {
            let base = Int32(sources.count)
            let hx = bw * 0.5, hy = bh * 0.5
            sources.append(SCNVector3(cx - hx, cy - hy, 0))
            sources.append(SCNVector3(cx + hx, cy - hy, 0))
            sources.append(SCNVector3(cx + hx, cy + hy, 0))
            sources.append(SCNVector3(cx - hx, cy + hy, 0))
            indices.append(contentsOf: [base, base+1, base+2, base, base+2, base+3])
        }
        bar(0, Float(h * 0.5), Float(w), Float(t))   // top
        bar(0, Float(-h * 0.5), Float(w), Float(t))  // bottom
        bar(Float(-w * 0.5), 0, Float(t), Float(h))   // left
        bar(Float(w * 0.5), 0, Float(t), Float(h))    // right
        let src = SCNGeometrySource(vertices: sources)
        let elem = SCNGeometryElement(indices: indices, primitiveType: .triangles)
        let geo = SCNGeometry(sources: [src], elements: [elem])
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(min(1, color.alphaComponent * 1.4))
        mat.lightingModel = .constant
        mat.writesToDepthBuffer = false
        mat.isDoubleSided = true
        geo.firstMaterial = mat
        return geo
    }

    /// Adds a thin cylinder (line) between two 3D points.
    @discardableResult
    private func addLine(from a: SIMD3<Float>, to b: SIMD3<Float>, radius: CGFloat,
                         color: NSColor, to root: SCNNode) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let length = max((dx*dx + dy*dy + dz*dz).squareRoot(), 0.001)
        let cyl = SCNCylinder(radius: radius, height: CGFloat(length))
        cyl.radialSegmentCount = 8
        let mat = SCNMaterial()
        mat.diffuse.contents = color
        mat.emission.contents = color.withAlphaComponent(min(1, color.alphaComponent * 1.3))
        mat.lightingModel = .constant
        mat.isDoubleSided = true
        cyl.firstMaterial = mat
        let node = SCNNode(geometry: cyl)
        node.simdPosition = SIMD3<Float>((a.x + b.x) * 0.5, (a.y + b.y) * 0.5, (a.z + b.z) * 0.5)
        // Align cylinder's Y axis with the direction a->b.
        if length > 0.001 {
            let dir = simd_normalize(SIMD3<Float>(dx, dy, dz))
            node.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: dir)
        }
        root.addChildNode(node)
        return node
    }

    // MARK: - Colors

    private func tokenColor(for owner: Owner) -> NSColor {
        switch owner {
        case .player1: return NSColor(calibratedRed: 0.93, green: 0.91, blue: highContrast ? 0.12 : 0.42, alpha: 1)
        case .player2: return NSColor(calibratedRed: 1.0, green: highContrast ? 0.16 : 0.28, blue: 0.18, alpha: 1)
        case .severed: return NSColor(calibratedRed: 0.42, green: 0.04, blue: 0.06, alpha: 1)
        case .neutral: return NSColor(calibratedRed: 0.38, green: highContrast ? 0.74 : 0.58, blue: 0.44, alpha: 0.7)
        }
    }

    private func tokenEmission(for owner: Owner, influence: Int) -> NSColor {
        let base = tokenColor(for: owner)
        let glow = max(0.25, min(1.0, 0.35 + Float(influence) / 100.0 * 0.55))
        return base.withAlphaComponent(CGFloat(glow))
    }

    private func edgeColor(for owner: Owner, kind: EdgeKind) -> NSColor {
        if kind == .conduit {
            return NSColor(calibratedRed: 0.30, green: 0.55, blue: 0.85, alpha: highContrast ? 0.9 : 0.7)
        }
        switch owner {
        case .player1: return tokenColor(for: .player1)
        case .player2: return tokenColor(for: .player2)
        case .severed: return NSColor(calibratedRed: 0.42, green: 0.04, blue: 0.06, alpha: 0.8)
        case .neutral: return NSColor(calibratedRed: 0.36, green: 0.63, blue: 0.44, alpha: highContrast ? 0.55 : 0.25)
        }
    }
}
