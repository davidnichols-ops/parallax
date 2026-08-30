import SwiftUI
import TacticalCore
import TacticalRenderer

/// Deterministic replay playback on the same native Metal board used for live
/// games. Seeking rebuilds from the command stream, so historical state never
/// depends on animation or a mutable UI cache.
public struct ReplayPlaybackView: View {
    @ObservedObject var app: AppState

    public init(app: AppState) { self.app = app }

    public var body: some View {
        ZStack {
            BoardMetalView(
                board: app.replayBoard,
                state: Binding(
                    get: { app.replayEngine?.state ?? app.engine.state },
                    set: { _ in }
                ),
                selectedNodeId: $app.selectedNodeId,
                cameraResetToken: $app.cameraResetToken
            )
            .ignoresSafeArea()

            VStack {
                header
                Spacer()
                controls
            }
            .padding(16)
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Replay Theater") { app.closeReplay() }
                Button("Reset Camera") { app.resetCamera() }
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("REPLAY PLAYBACK")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                Text("\(app.replayBoard.id.uppercased())  •  TICK \(app.replayEngine?.state.tick ?? 0)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(app.replayPosition) / \(app.replayTickCount)")
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 10) {
            Slider(
                value: Binding(
                    get: { Double(app.replayPosition) },
                    set: { app.seekReplay(to: Int($0.rounded())) }
                ),
                in: 0...Double(max(1, app.replayTickCount)),
                step: 1
            )
            HStack(spacing: 14) {
                Button("◀ Previous") { app.stepReplayBackward() }
                    .disabled(app.replayPosition == 0)
                Button("Next ▶") { app.stepReplayForward() }
                    .buttonStyle(.borderedProminent)
                    .disabled(app.replayPosition >= app.replayTickCount)
                Button("Back to Theater") { app.closeReplay() }
            }
            if !app.replayStatus.isEmpty {
                Text(app.replayStatus)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
