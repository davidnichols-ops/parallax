import SwiftUI
import TacticalCore
import TacticalPersistence

/// Replay Theater — browse, load, and verify saved replays.
public struct ReplayTheaterView: View {
    @ObservedObject var app: AppState

    public init(app: AppState) { self.app = app }

    public var body: some View {
        VStack(spacing: 24) {
            Text("Replay Theater")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)

            if !app.replayStatus.isEmpty {
                Text(app.replayStatus)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(app.replayStatus.hasPrefix("Verified") ? .green : .orange)
            }

            if app.savedReplays.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.tertiary)
                    Text("No saved replays yet")
                        .font(.system(size: 16, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Play a match to generate your first replay")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(app.savedReplays, id: \.self) { url in
                            replayRow(url)
                        }
                    }
                    .padding(.horizontal, 40)
                }
            }

            Button("Back to Menu") { app.showMenu() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 20)
                .accessibilityIdentifier("replay.back")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
    }

    private func replayRow(_ url: URL) -> some View {
        let replay = (try? app.persistence.loadReplay(from: url)) ?? nil
        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(url.lastPathComponent)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white)
                if let r = replay {
                    Text("Board: \(r.boardId)  •  Ticks: \(r.durationTicks)  •  \(r.player1Type.rawValue) vs \(r.player2Type.rawValue)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("Hash: \(r.finalSnapshotHash.prefix(16))…")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if replay != nil {
                Button("Open") { app.openReplay(url) }
                    .buttonStyle(.borderedProminent)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
