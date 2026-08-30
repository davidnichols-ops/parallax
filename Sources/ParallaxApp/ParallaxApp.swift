import SwiftUI
import TacticalCore

/// Parallax — native macOS strategy game.
/// SwiftUI App entry point.
@main
struct ParallaxApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Parallax") {
            rootView
                .frame(minWidth: 900, minHeight: 650)
                .background(Color(red: 0.04, green: 0.05, blue: 0.08))
                // Mount before a match starts so its first key cannot fall
                // between the menu disappearing and the board mounting.
                .background(WindowInputBridge(app: appState).frame(width: 0, height: 0))
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Game") {
                Button("New Skirmish") { appState.startSkirmish() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Standoff") { appState.startStandoff() }
                    .keyboardShortcut("s", modifiers: .command)
                Button("Training Academy") { appState.showTraining() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Pause/Resume") { appState.pauseToggle() }
                    .keyboardShortcut("p", modifiers: .command)
                Button("Main Menu") { appState.showMenu() }
                    .keyboardShortcut("m", modifiers: .command)
            }
            CommandMenu("Camera") {
                Button("Reset Camera") { appState.resetCamera() }
                    .keyboardShortcut("r", modifiers: .command)
            }
            CommandMenu("View") {
                Button("Replay Theater") { appState.showReplayTheater() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("Settings") { appState.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        switch appState.screen {
        case .menu:
            MenuView(app: appState)
        case .skirmish, .standoff, .hotseat:
            MatchView(app: appState)
        case .result:
            if let result = appState.lastResult {
                ResultView(app: appState, result: result)
            } else {
                MenuView(app: appState)
            }
        case .settings:
            SettingsView(app: appState)
        case .training:
            TrainingView(app: appState)
        case .replayTheater:
            ReplayTheaterView(app: appState)
        case .replayPlayback:
            ReplayPlaybackView(app: appState)
        }
    }
}
