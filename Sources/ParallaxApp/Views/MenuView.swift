import SwiftUI
import TacticalCore
import TacticalBots
import TacticalRenderer

public struct MenuView: View {
    @ObservedObject var app: AppState

    public init(app: AppState) { self.app = app }

    public var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Circle().fill(GameTheme.teal).frame(width: 5, height: 5)
                            Text("PARALLAX / HOLOGRAPHIC STRATEGY")
                                .font(.system(size: 8, weight: .medium, design: .monospaced))
                                .tracking(1.3)
                        }
                        .foregroundStyle(GameTheme.teal)
                        Text("STRATEGEMA")
                            .font(.system(size: 34, weight: .light, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(GameTheme.ink)
                        Text("A contest of precision.\nA victory of patience.")
                            .font(.system(size: 15, weight: .light))
                            .lineSpacing(5)
                            .foregroundStyle(GameTheme.muted)
                    }

                    VStack(spacing: 8) {
                        modeButton("Enter the arena", detail: "Solo match against a thinking opponent", number: "01", primary: true) {
                            app.startSkirmish()
                        }
                        modeButton("Training academy", detail: "Eight hands-on lessons, one move at a time", number: "02") {
                            app.showTraining()
                        }
                        modeButton("Standoff", detail: "Hold parity. Refuse the decisive exchange.", number: "03") {
                            app.startStandoff()
                        }
                        modeButton("Local duel", detail: "Two players. One board. Alternating inputs.", number: "04") {
                            app.startHotSeat()
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("CONFIGURE THE CONTEST")
                            .font(.system(size: 8, weight: .medium, design: .monospaced))
                            .tracking(2).foregroundStyle(GameTheme.muted)
                        Picker("Board", selection: $app.boardId) {
                            Text("Triad · 3 planes").tag("triad")
                            Text("Grandmaster · 6").tag("grandmaster")
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: app.boardId) { _, _ in app.savePreferences() }

                        HStack {
                            Text("Opponent").font(.system(size: 11)).foregroundStyle(GameTheme.muted)
                            Spacer()
                            Picker("Opponent", selection: $app.botDifficulty) {
                                Text("Novice").tag(GrandmasterBot.Difficulty.novice)
                                Text("Adept").tag(GrandmasterBot.Difficulty.adept)
                                Text("Master").tag(GrandmasterBot.Difficulty.master)
                                Text("Grandmaster").tag(GrandmasterBot.Difficulty.grandmaster)
                            }
                            .labelsHidden().frame(width: 150)
                            .onChange(of: app.botDifficulty) { _, _ in app.savePreferences() }
                        }
                    }

                    HStack(spacing: 10) {
                        Button("Replay theater") { app.showReplayTheater() }
                            .accessibilityIdentifier("menu.replay")
                        Button("Settings") { app.showSettings() }
                            .accessibilityIdentifier("menu.settings")
                    }
                    .buttonStyle(ConsoleButtonStyle())

                    Text("An independent fan recreation inspired by the\nStrategema table in The Next Generation.\nOriginal rules, geometry, and synthesized audio.")
                        .font(.system(size: 9))
                        .lineSpacing(3)
                        .foregroundStyle(GameTheme.muted.opacity(0.7))
                }
                .padding(28)
            }
            .frame(width: 358)
            .background(GameTheme.background)
            .overlay(alignment: .trailing) { GameTheme.teal.opacity(0.16).frame(width: 1) }

            ZStack {
                BoardMetalView(
                    board: previewBoard,
                    state: .constant(GameState(board: previewBoard, matchSeed: 0xC0FFEE)),
                    selectedNodeId: .constant(nil),
                    reduceMotion: app.reduceMotion,
                    highContrast: app.highContrast || app.colorVisionSafe
                )
                .allowsHitTesting(false)
                VStack {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("THE TABLE IS READY")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .tracking(2.8).foregroundStyle(GameTheme.teal)
                            Text("Upright planes. Interwoven territory.")
                                .font(.system(size: 13, weight: .light))
                                .foregroundStyle(GameTheme.ink)
                        }
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Text("\(previewBoard.plateaus.count) PLANES  /  \(previewBoard.nodes.count) NODES")
                        Spacer()
                        Text("STATIC 3D")
                    }
                    .font(.system(size: 8, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(GameTheme.muted)
                }
                .padding(26)
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GameTheme.background)
        .preferredColorScheme(.dark)
    }

    private var previewBoard: BoardDefinition {
        app.boardId == "grandmaster" ? BoardFactory.grandmaster() : BoardFactory.triad()
    }

    private func modeButton(_ title: String, detail: String, number: String,
                            primary: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 13) {
                Text(number)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(primary ? GameTheme.gold : GameTheme.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 15, weight: .medium))
                        .foregroundStyle(GameTheme.ink)
                    Text(detail).font(.system(size: 10))
                        .foregroundStyle(GameTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 11))
                    .foregroundStyle(primary ? GameTheme.gold : GameTheme.muted)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary ? GameTheme.gold.opacity(0.08) : GameTheme.panel.opacity(0.5))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke((primary ? GameTheme.gold : GameTheme.teal).opacity(primary ? 0.45 : 0.15)) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("menu.mode.\(number)")
    }
}
