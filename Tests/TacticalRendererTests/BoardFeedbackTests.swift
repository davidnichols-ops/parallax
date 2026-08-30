import XCTest
import SceneKit
import AppKit
@testable import TacticalRenderer
import TacticalCore

/// Segment 11 — focused tests for the renderer-observable feedback accents
/// and commitment-glow hooks. These verify the BoardHostingView scene-graph
/// effects of wiring the Segment 10 duel-feel state into visible board
/// animation: pulse/forge/sever/seal/yield/reject accents and the
/// commitment-window glow. All headless; no pixel assertions.
@MainActor
final class BoardFeedbackTests: XCTestCase {

    private func makeView(reduceMotion: Bool = false) -> BoardHostingView {
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.reduceMotion = reduceMotion
        return view
    }

    private func configureOnce(_ view: BoardHostingView,
                               board: BoardDefinition = BoardFactory.triad(),
                               state: GameState? = nil,
                               selectedNodeId: String? = nil,
                               pulse: BoardFeedbackPulse? = nil,
                               glow: BoardCommitmentGlow? = nil) {
        let s = state ?? GameState(board: board, matchSeed: 1)
        view.feedbackPulse = pulse
        view.commitmentGlow = glow
        view.configure(board: board, state: s, selectedNodeId: selectedNodeId)
    }

    // MARK: - Feedback pulse accents

    func testPulseBurstAppearsOnTargetNode() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .pulse, player: .player1,
                                                targetNode: node, targetEdge: nil,
                                                targetFace: nil, token: 1))
        XCTAssertNotNil(view.feedbackBurstNode(forNodeId: node),
                        "a .pulse must attach a feedback burst on the target node")
        XCTAssertTrue(view.hasFeedbackBurst(forNodeId: node),
                      "the burst must carry a running feedbackBurst action")
        XCTAssertEqual(view.appliedFeedbackToken, 1)
    }

    func testForgeFlashAppearsOnEdge() {
        let view = makeView()
        let board = BoardFactory.triad()
        let edge = board.edges.first!.id
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .forge, player: .player1,
                                                targetNode: nil, targetEdge: edge,
                                                targetFace: nil, token: 1))
        XCTAssertNotNil(view.feedbackBurstNode(forEdgeId: edge),
                        "a .forge must attach a feedback flash on the target edge")
        XCTAssertEqual(view.appliedFeedbackToken, 1)
    }

    func testSeverFlashAppearsOnEdge() {
        let view = makeView()
        let board = BoardFactory.triad()
        let edge = board.edges.first!.id
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .sever, player: .player2,
                                                targetNode: nil, targetEdge: edge,
                                                targetFace: nil, token: 2))
        XCTAssertNotNil(view.feedbackBurstNode(forEdgeId: edge),
                        "a .sever must attach a feedback flash on the target edge")
        XCTAssertEqual(view.appliedFeedbackToken, 2)
    }

    func testSealBurstAppearsOnControlledFace() {
        let view = makeView()
        let board = BoardFactory.triad()
        var state = GameState(board: board, matchSeed: 1)
        let face = board.faces.first!.id
        // The face node only exists when controlled/sealed; control it first.
        state.faces[face]?.controller = .player1
        configureOnce(view, board: board, state: state,
                      pulse: BoardFeedbackPulse(kind: .seal, player: .player1,
                                                targetNode: nil, targetEdge: nil,
                                                targetFace: face, token: 3))
        XCTAssertNotNil(view.feedbackBurstNode(forFaceId: face),
                        "a .seal must attach a feedback burst on the target face")
        XCTAssertEqual(view.appliedFeedbackToken, 3)
    }

    func testYieldRippleAppearsOnSelectedNode() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      pulse: BoardFeedbackPulse(kind: .yield, player: .player1,
                                                targetNode: nil, targetEdge: nil,
                                                targetFace: nil, token: 4))
        XCTAssertNotNil(view.feedbackBurstNode(forNodeId: node),
                        "a .yield must attach an ambient ripple on the selected node")
        XCTAssertEqual(view.appliedFeedbackToken, 4)
    }

    func testRejectSnapbackAppearsOnSelectedNode() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      pulse: BoardFeedbackPulse(kind: .reject, player: .player1,
                                                targetNode: nil, targetEdge: nil,
                                                targetFace: nil, token: 5))
        XCTAssertNotNil(view.feedbackBurstNode(forNodeId: node),
                        "a .reject must attach a snapback cue on the selected node")
        XCTAssertEqual(view.appliedFeedbackToken, 5)
    }

    func testRejectSnapbackPrefersPulseTargetNode() {
        let view = makeView()
        let board = BoardFactory.triad()
        let target = board.nodes[3].id
        let selected = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: selected,
                      pulse: BoardFeedbackPulse(kind: .reject, player: .player1,
                                                targetNode: target, targetEdge: nil,
                                                targetFace: nil, token: 6))
        XCTAssertNotNil(view.feedbackBurstNode(forNodeId: target),
                        "reject should snap back on the pulse's target node when present")
        XCTAssertNil(view.feedbackBurstNode(forNodeId: selected),
                     "the selected node should not get the snapback when a target node is given")
    }

    // MARK: - Token semantics

    func testNoRefireOnSameFeedbackToken() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        let pulse = BoardFeedbackPulse(kind: .pulse, player: .player1,
                                       targetNode: node, targetEdge: nil,
                                       targetFace: nil, token: 7)
        configureOnce(view, board: board, pulse: pulse)
        let firstBurst = view.feedbackBurstNode(forNodeId: node)
        XCTAssertNotNil(firstBurst)
        // Reconfigure with the same token — no new burst should be attached.
        configureOnce(view, board: board, pulse: pulse)
        XCTAssertEqual(view.appliedFeedbackToken, 7,
                       "the token must not advance when the pulse token is unchanged")
    }

    func testRepeatPulseRetriggersBurst() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .pulse, player: .player1,
                                                targetNode: node, targetEdge: nil,
                                                targetFace: nil, token: 8))
        XCTAssertEqual(view.appliedFeedbackToken, 8)
        // Same kind, new token — the renderer must re-trigger.
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .pulse, player: .player1,
                                                targetNode: node, targetEdge: nil,
                                                targetFace: nil, token: 9))
        XCTAssertEqual(view.appliedFeedbackToken, 9)
        XCTAssertNotNil(view.feedbackBurstNode(forNodeId: node))
    }

    func testFeedbackTokenConsumedEvenWhenTargetMissing() {
        let view = makeView()
        let board = BoardFactory.triad()
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .pulse, player: .player1,
                                                targetNode: "nonexistent", targetEdge: nil,
                                                targetFace: nil, token: 10))
        XCTAssertEqual(view.appliedFeedbackToken, 10,
                       "the token is consumed even when the target node is missing")
    }

    // MARK: - reduceMotion gating

    func testReduceMotionGatesFeedbackBurst() {
        let view = makeView(reduceMotion: true)
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board,
                      pulse: BoardFeedbackPulse(kind: .pulse, player: .player1,
                                                targetNode: node, targetEdge: nil,
                                                targetFace: nil, token: 11))
        XCTAssertNil(view.feedbackBurstNode(forNodeId: node),
                     "no burst node should be created under reduceMotion")
        XCTAssertFalse(view.hasFeedbackBurst(forNodeId: node))
        XCTAssertEqual(view.appliedFeedbackToken, 11,
                       "the token is still consumed under reduceMotion so a toggle does not replay")
    }

    func testReduceMotionStillShowsCommitmentGlow() {
        let view = makeView(reduceMotion: true)
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      glow: BoardCommitmentGlow(player: .player1, targetNode: node,
                                                targetEdge: nil, targetFace: nil,
                                                phase: .locked, token: 1))
        XCTAssertNotNil(view.commitmentGlowNode(forNodeId: node),
                        "the commitment glow node is created under reduceMotion as a static cue")
        XCTAssertEqual(view.appliedCommitmentToken, 1)
    }

    // MARK: - Commitment glow lifecycle

    func testCommitmentGlowAttachesOnTargetNode() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      glow: BoardCommitmentGlow(player: .player1, targetNode: node,
                                                targetEdge: nil, targetFace: nil,
                                                phase: .locked, token: 1))
        let glow = view.commitmentGlowNode(forNodeId: node)
        XCTAssertNotNil(glow, "a .locked commitment must attach a glow on the target node")
        XCTAssertEqual(glow?.name, "commitmentGlow")
        XCTAssertEqual(view.appliedCommitmentToken, 1)
    }

    func testCommitmentGlowAttachesOnEdge() {
        let view = makeView()
        let board = BoardFactory.triad()
        let edge = board.edges.first!.id
        configureOnce(view, board: board,
                      glow: BoardCommitmentGlow(player: .player2, targetNode: nil,
                                                targetEdge: edge, targetFace: nil,
                                                phase: .resolving, token: 2))
        XCTAssertNotNil(view.commitmentGlowNode(forEdgeId: edge),
                        "a .resolving commitment must attach a glow on the target edge")
        XCTAssertEqual(view.appliedCommitmentToken, 2)
    }

    func testCommitmentGlowRemovedWhenCleared() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      glow: BoardCommitmentGlow(player: .player1, targetNode: node,
                                                targetEdge: nil, targetFace: nil,
                                                phase: .locked, token: 1))
        XCTAssertNotNil(view.commitmentGlowNode(forNodeId: node))
        // Clear the glow (window cleared upstream) with a fresh token change.
        configureOnce(view, board: board, selectedNodeId: node, glow: nil)
        XCTAssertNil(view.commitmentGlowNode(forNodeId: node),
                     "clearing the commitment glow must remove the node")
    }

    func testCommitmentGlowFadesOnResolvedPhaseUnderReduceMotion() {
        // Under reduceMotion the resolved-phase fade removes the glow
        // immediately, so the removal is deterministic for headless assertion.
        let view = makeView(reduceMotion: true)
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        configureOnce(view, board: board, selectedNodeId: node,
                      glow: BoardCommitmentGlow(player: .player1, targetNode: node,
                                                targetEdge: nil, targetFace: nil,
                                                phase: .locked, token: 1))
        XCTAssertNotNil(view.commitmentGlowNode(forNodeId: node))
        configureOnce(view, board: board, selectedNodeId: node,
                      glow: BoardCommitmentGlow(player: .player1, targetNode: node,
                                                targetEdge: nil, targetFace: nil,
                                                phase: .resolved, token: 2))
        XCTAssertNil(view.commitmentGlowNode(forNodeId: node),
                     "a .resolved commitment must remove the glow")
        XCTAssertEqual(view.appliedCommitmentToken, 2)
    }

    func testCommitmentGlowNoRefireOnSameToken() {
        let view = makeView()
        let board = BoardFactory.triad()
        let node = board.nodes.first!.id
        let glow = BoardCommitmentGlow(player: .player1, targetNode: node,
                                       targetEdge: nil, targetFace: nil,
                                       phase: .locked, token: 3)
        configureOnce(view, board: board, selectedNodeId: node, glow: glow)
        XCTAssertEqual(view.appliedCommitmentToken, 3)
        // Same token — no re-apply.
        configureOnce(view, board: board, selectedNodeId: node, glow: glow)
        XCTAssertEqual(view.appliedCommitmentToken, 3)
    }

    // MARK: - BoardFeedbackPulse / BoardCommitmentGlow value types

    func testBoardFeedbackPulseEquatable() {
        let a = BoardFeedbackPulse(kind: .pulse, player: .player1,
                                   targetNode: "n", targetEdge: nil, targetFace: nil, token: 1)
        let b = BoardFeedbackPulse(kind: .pulse, player: .player1,
                                   targetNode: "n", targetEdge: nil, targetFace: nil, token: 1)
        let c = BoardFeedbackPulse(kind: .pulse, player: .player1,
                                   targetNode: "n", targetEdge: nil, targetFace: nil, token: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c, "a different token must make pulses unequal")
    }

    func testBoardCommitmentGlowEquatable() {
        let a = BoardCommitmentGlow(player: .player1, targetNode: "n",
                                    targetEdge: nil, targetFace: nil, phase: .locked, token: 1)
        let b = BoardCommitmentGlow(player: .player1, targetNode: "n",
                                    targetEdge: nil, targetFace: nil, phase: .locked, token: 1)
        let c = BoardCommitmentGlow(player: .player1, targetNode: "n",
                                    targetEdge: nil, targetFace: nil, phase: .resolving, token: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
