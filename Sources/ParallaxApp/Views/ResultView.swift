import SwiftUI
import TacticalCore

/// Post-match results screen.
public struct ResultView: View {
    @ObservedObject var app: AppState
    let result: MatchResult

    public init(app: AppState, result: MatchResult) {
        self.app = app
        self.result = result
    }

    public var body: some View {
        VStack(spacing: 32) {
            VStack(spacing: 8) {
                Text("MATCH COMPLETE")
                    .font(.system(size: 32, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                if let winner = result.winner {
                    let reasonText: String = switch result.endReason {
                    case .decisiveScore: "Decisive Score"
                    case .resignation: "Resignation"
                    case .boardExhaustion: "Board Exhaustion"
    case .timeout: "Timeout"
                    case .voided: "Voided"
                    case nil: "Unknown"
                    }
                    Text("\(winner.label) wins — \(reasonText)")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(winner == .player1 ? Color(red: 0.95, green: 0.75, blue: 0.3) : Color(red: 0.3, green: 0.7, blue: 0.95))
                } else {
                    Text("Draw — Board Exhaustion")
                        .font(.system(size: 18, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 16) {
                HStack(spacing: 48) {
                    resultColumn("P1", score: result.p1Score, moves: result.p1Moves,
                                 composure: result.p1Composure,
                                 color: Color(red: 0.95, green: 0.75, blue: 0.3))
                    resultColumn("P2", score: result.p2Score, moves: result.p2Moves,
                                 composure: result.p2Composure,
                                 color: Color(red: 0.3, green: 0.7, blue: 0.95))
                }

                Divider().frame(width: 400)

                VStack(spacing: 4) {
                    statRow("Ticks", "\(result.tick)")
                    statRow("Events", "\(result.eventCount)")
                    statRow("Snapshot Hash", String(result.snapshotHash.prefix(16)) + "…")
                    statRow("Event Log Hash", String(result.eventLogHash.prefix(16)) + "…")
                }
            }

            VStack(spacing: 12) {
                Button("Rematch") { app.rematch() }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("result.rematch")
                Button("Main Menu") { app.showMenu() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("result.menu")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
    }

    private func resultColumn(_ label: String, score: Int, moves: Int,
                              composure: Int, color: Color) -> some View {
        VStack(spacing: 8) {
            HStack {
                Circle().fill(color).frame(width: 12, height: 12)
                Text(label).font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
            statRow("Score", "\(score)")
            statRow("Moves", "\(moves)")
            statRow("Composure", "\(composure)")
        }
        .frame(width: 160)
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
                .font(.system(size: 12, design: .monospaced))
            Spacer()
            Text(value).foregroundStyle(.white)
                .font(.system(size: 12, design: .monospaced))
        }
        .frame(width: 200)
    }
}
