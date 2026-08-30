import SwiftUI
import TacticalCore
import TacticalBots
import TacticalRenderer

/// Segment 13 — pure, testable mappers for the grandmaster persona HUD strip.
/// These map the Segment 12 published observation state (`duelPersona`,
/// `opponentThinkingPhase`, `opponentAdaptation`, `lastBotDecisionExplanation`)
/// to the labels and colors the MatchView persona strip renders. Pure functions
/// of the observation state only; never mutate the engine, the bot, or any
/// Segment 10/11 hook. Extracted from MatchView so the mapping is directly
/// testable without mounting a SwiftUI view.
public enum PersonaHUD {

    /// The thinking-phase caption shown in the strip, or "—" before the first
    /// bot move resolves so the readout is always present.
    public static func thinkingPhaseLabel(_ phase: ThinkingPhase?) -> String {
        phase?.caption ?? "—"
    }

    /// Thinking-phase color, mapped from the phase so the accent reflects the
    /// kind of thought (threatening = gold, disrupting = red, etc.). The
    /// "pending" color (no phase yet) is a dimmed muted.
    public static func thinkingPhaseColor(_ phase: ThinkingPhase?) -> Color {
        guard let phase else { return GameTheme.muted.opacity(0.6) }
        switch phase {
        case .scanning:       return GameTheme.muted
        case .threatening:    return GameTheme.gold
        case .disrupting:     return GameTheme.red
        case .consolidating:  return GameTheme.teal
        case .bluffing:       return GameTheme.lavender
        case .committing:     return GameTheme.gold
        }
    }

    /// Adaptation-pressure color, mapped from the bounded label.
    public static func adaptationColor(_ adaptation: AdaptiveDifficulty.Adaptation) -> Color {
        switch adaptation {
        case .relaxing:   return GameTheme.muted
        case .holding:    return GameTheme.teal
        case .tightening: return GameTheme.red
        }
    }

    /// The persona's voice line for their last decision, board-readable so
    /// node/edge ids render as human-friendly coordinates. nil before the
    /// first bot move resolves.
    public static func voiceLine(for explanation: DecisionExplanation?,
                                 board: BoardDefinition) -> String? {
        guard let explanation else { return nil }
        return GameTheme.readable(explanation.voiceLine, board: board)
    }

    /// A single combined accessibility label for the whole persona strip so
    /// VoiceOver reads the opponent as one coherent presence: name, thinking
    /// phase, pressure, and the reasoning behind their last move (the
    /// persona-neutral reasoning is more informative for AT users than the
    /// flavor voice line, which is already shown visually).
    public static func accessibilityLabel(
        persona: DuelPersona,
        thinkingPhase: ThinkingPhase?,
        adaptation: AdaptiveDifficulty.Adaptation,
        explanation: DecisionExplanation?,
        board: BoardDefinition
    ) -> String {
        var parts: [String] = []
        parts.append("Opponent \(persona.displayName)")
        if let phase = thinkingPhase {
            parts.append("thinking \(phase.caption.lowercased())")
        } else {
            parts.append("awaiting first move")
        }
        parts.append("pressure \(adaptation.caption.lowercased())")
        if let explanation {
            parts.append(GameTheme.readable(explanation.reasoning, board: board))
        }
        return parts.joined(separator: ", ")
    }
}

/// Segment 18 — pure, testable mappers for the camera controls overlay.
///
/// The match console and the Controls sheet both surface the restored
/// (Segment 17) camera orbit/pan/zoom/reset affordances. Extracting the
/// labels here as pure static constants lets the overlay content be
/// asserted directly without mounting a SwiftUI view, mirroring the
/// `PersonaHUD` pattern. These never mutate the engine, the renderer, or
/// any input hook — they are presentation strings only.
public enum ControlsOverlay {

    /// Compact single-line camera hint shown in the match console bottom
    /// row. Kept short so it never clutters gameplay; the full detail lives
    /// in the Controls sheet (`cameraHelpRows`).
    public static let cameraHintLabel = "DRAG·ORBIT  ⌥⇧·PAN  SCROLL·ZOOM"

    /// Camera section heading in the Controls sheet.
    public static let cameraSectionHeading = "Camera"

    /// One-line summary shown under the Camera heading in the Controls sheet.
    public static let cameraSectionSummary =
        "The board is a live 3D scene. Orbit, pan, and zoom with the mouse; reset to the default angle at any time."

    /// Camera control help rows (key, detail) for the Controls sheet. Each
    /// row pairs a gesture with a short description so a player can find the
    /// camera controls without trial-and-error.
    public static let cameraHelpRows: [(key: String, detail: String)] = [
        ("DRAG / RIGHT-DRAG", "Orbit the camera around the board."),
        ("⌥⇧-DRAG", "Pan the camera target across the board."),
        ("SCROLL", "Zoom the camera in and out."),
        ("RESET VIEW", "Restore the default camera angle — button below the board.")
    ]
}

/// The board gets its own unobscured viewport; controls are native buttons,
/// not painted hit regions inside the renderer.
public struct MatchView: View {
    @ObservedObject var app: AppState
    @State private var showsHelp = false
    @State private var wasPausedBeforeHelp = false
    @State private var showsTargets = false

    public init(app: AppState) { self.app = app }

    public var body: some View {
        ZStack {
            GameTheme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                header
                if app.currentLesson != nil { lessonStrip }
                if showsPersonaStrip { personaStrip }
                board
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(!app.isPaused && !app.trainingComplete)
                console
            }
            if app.isPaused && !app.trainingComplete { pauseOverlay }
            if app.trainingComplete { completionOverlay }
        }
        .sheet(isPresented: $showsHelp, onDismiss: closeHelp) {
            controlsSheet
        }
        .preferredColorScheme(.dark)
    }

    /// Segment 13 — the grandmaster persona is surfaced only in solo bot
    /// modes (skirmish/standoff). Hot-seat has no bot; training is solo with
    /// no opponent. Keeping the strip gated avoids clutter on screens where
    /// there is no grandmaster to project a persona.
    private var showsPersonaStrip: Bool {
        (app.screen == .skirmish || app.screen == .standoff) && app.currentLesson == nil
    }

    private var board: some View {
        BoardMetalView(
            board: app.board,
            state: Binding(get: { app.engine.state }, set: { _ in }),
            selectedNodeId: $app.selectedNodeId,
            cameraResetToken: $app.cameraResetToken,
            onKeyEvent: { event, down in app.handleBoardKeyEvent(event, isDown: down) },
            onFocusLost: { app.releaseBoardInput() },
            onNodeSelected: { app.selectBoardNode($0) },
            onTabletopControl: { control in
                switch control {
                case .pulse: app.pulseSelectedBoardNode()
                case .yield: app.yieldBoardTurn()
                case .pause: app.pauseToggle()
                case .menu: app.showMenu()
                case .help: openHelp()
                }
            },
            reduceMotion: app.reduceMotion,
            highContrast: app.highContrast || app.colorVisionSafe,
            feedbackPulse: app.boardFeedbackPulse,
            commitmentGlow: app.boardCommitmentGlow
        )
        .accessibilityLabel("Holographic game board. Arrow keys select nodes; Space pulses.")
    }

    private var header: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 3) {
                Text("STRATEGEMA")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .tracking(3)
                    .foregroundStyle(GameTheme.ink)
                Text(modeName)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(GameTheme.muted)
            }
            Spacer(minLength: 8)
            score(.player1, title: "PLAYER ONE")
            VStack(spacing: 3) {
                Text(String(format: "%05d", app.engine.state.tick))
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(GameTheme.ink)
                Text(opponentStatusLabel)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(opponentStatusColor)
            }
            score(.player2, title: app.currentLesson != nil ? "ACADEMY" : (app.screen == .hotseat ? "PLAYER TWO" : "OPPONENT"))
            Spacer(minLength: 8)
            HStack(spacing: 6) {
                Button("Menu") { app.showMenu() }
                    .accessibilityIdentifier("match.menu")
                Button(app.isPaused ? "Resume" : "Pause") { app.pauseToggle() }
                    .accessibilityIdentifier("match.pause")
                Button("Controls") { openHelp() }
                    .accessibilityIdentifier("match.controls")
            }
            .buttonStyle(ConsoleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(GameTheme.background)
        .overlay(alignment: .bottom) { GameTheme.teal.opacity(0.25).frame(height: 1) }
    }

    private var modeName: String {
        if app.currentLesson != nil { return "ACADEMY / TRAINING" }
        switch app.screen {
        case .hotseat: return "LOCAL DUEL / \(app.activePlayer.label) INPUT"
        case .standoff: return "STANDOFF / HOLD PARITY"
        default: return "SOLO / \(app.board.plateaus.count) PLANES"
        }
    }

    private func score(_ player: Player, title: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1.5)
            Text(String(format: "%05d", app.engine.state.playerStates[player]?.score ?? 0))
                .font(.system(size: 27, weight: .medium, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(player == .player1 ? GameTheme.gold : GameTheme.red)
        .shadow(color: (player == .player1 ? GameTheme.gold : GameTheme.red).opacity(0.3), radius: 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), score \(app.engine.state.playerStates[player]?.score ?? 0)")
    }

    private var lessonStrip: some View {
        HStack(spacing: 16) {
            Text(app.trainingLessonTitle.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(GameTheme.gold)
            Text(GameTheme.readable(app.trainingObjective, board: app.board))
                .font(.system(size: 11))
                .foregroundStyle(GameTheme.ink)
                .lineLimit(2)
            Spacer(minLength: 0)
            Text("\(app.trainingMoveCount) / \(app.trainingParMoves) MOVES")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(GameTheme.muted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(GameTheme.panel)
    }

    // MARK: - Segment 13 — grandmaster persona HUD strip

    /// A compact, always-present readout that makes the grandmaster opponent
    /// feel present during a solo match. Shows the persona name, the visible
    /// thinking phase, the bounded adaptation pressure, and the persona's
    /// voice line for their last decision. Reads only Segment 12 published
    /// state; never mutates the engine, the bot, or any Segment 10/11 hook.
    /// Stays uncluttered: one line, no instructional text, no extra chrome.
    private var personaStrip: some View {
        HStack(spacing: 14) {
            // Persona name — always shown so the opponent has a persistent
            // identity in the HUD, even before the first bot move resolves.
            Text(app.duelPersona.displayName.uppercased())
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(GameTheme.gold)
                .accessibilityIdentifier("match.persona.name")
            Divider().frame(height: 14)
            // Thinking phase — the "what kind of thought" companion to the
            // Segment 10 opponent-tempo chip. Shows "—" before the first bot
            // move so the readout is always present but never empty.
            Text(thinkingPhaseLabel)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(thinkingPhaseColor)
                .accessibilityIdentifier("match.persona.thinking")
            // Adaptation pressure — the bounded EASING/STEADY/PRESSING label.
            // Reads the bot's pure adaptive label at the current state.
            Text(app.opponentAdaptation.caption)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(adaptationColor)
                .accessibilityIdentifier("match.persona.pressure")
            Spacer(minLength: 8)
            // Last decision voice line — the persona's original phrasing for
            // their most recent move. Truncated to one line so the strip stays
            // a single row. Empty before the first bot move.
            if let voiceLine = personaVoiceLine {
                Text(voiceLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GameTheme.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("match.persona.explanation")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 7)
        .background(GameTheme.panel)
        .overlay(alignment: .bottom) { GameTheme.gold.opacity(0.18).frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(personaAccessibilityLabel)
        .accessibilityIdentifier("match.persona.strip")
    }

    /// The thinking-phase caption shown in the strip, or "—" before the first
    /// bot move resolves so the readout is always present.
    private var thinkingPhaseLabel: String {
        PersonaHUD.thinkingPhaseLabel(app.opponentThinkingPhase)
    }

    /// Thinking-phase color, mapped from the phase so the accent reflects the
    /// kind of thought (threatening = gold, disrupting = red, etc.).
    private var thinkingPhaseColor: Color {
        PersonaHUD.thinkingPhaseColor(app.opponentThinkingPhase)
    }

    /// Adaptation-pressure color, mapped from the bounded label.
    private var adaptationColor: Color {
        PersonaHUD.adaptationColor(app.opponentAdaptation)
    }

    /// The persona's voice line for their last decision, board-readable so
    /// node/edge ids render as human-friendly coordinates. nil before the
    /// first bot move resolves.
    private var personaVoiceLine: String? {
        PersonaHUD.voiceLine(for: app.lastBotDecisionExplanation, board: app.board)
    }

    /// A single combined accessibility label for the whole persona strip so
    /// VoiceOver reads the opponent as one coherent presence: name, thinking
    /// phase, pressure, and the reasoning behind their last move (the
    /// persona-neutral reasoning is more informative for AT users than the
    /// flavor voice line, which is already shown visually).
    private var personaAccessibilityLabel: String {
        PersonaHUD.accessibilityLabel(
            persona: app.duelPersona,
            thinkingPhase: app.opponentThinkingPhase,
            adaptation: app.opponentAdaptation,
            explanation: app.lastBotDecisionExplanation,
            board: app.board
        )
    }

    private var console: some View {
        VStack(spacing: 9) {
            HStack(spacing: 12) {
                Circle().fill(GameTheme.gold).frame(width: 5, height: 5)
                Text(nodeLabel(app.selectedNodeId))
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(GameTheme.ink)
                Text("PLANE")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(GameTheme.muted)
                ForEach(app.board.plateaus, id: \.index) { plateau in
                    Button("\(plateau.index + 1)") { selectPlane(plateau.index) }
                        .buttonStyle(ConsoleButtonStyle(accent: selectedPlateau == plateau.index ? GameTheme.teal : GameTheme.muted))
                        .accessibilityLabel("Select plane \(plateau.index + 1)")
                        .accessibilityIdentifier("match.plane.\(plateau.index)")
                }
                Spacer(minLength: 4)
                Text("FLUX \(app.engine.state.playerStates[app.activePlayer]?.flux ?? 0)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(GameTheme.teal)
                Text(tempoChipLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(tempoChipColor)
                    .accessibilityIdentifier("match.tempo")
                Text(pulseChipLabel)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(pulseChipColor)
                    .accessibilityIdentifier("match.pulse")
                Button(showsTargets ? "Hide targets" : "Link / region targets") { showsTargets.toggle() }
                    .buttonStyle(ConsoleButtonStyle())
                    .accessibilityIdentifier("match.targets")
            }

            if showsTargets { targetPickers }

            HStack(spacing: 6) {
                ForEach(AppState.BoardAction.allCases) { action in
                    actionButton(action)
                }
                Button { app.yieldBoardTurn() } label: {
                    VStack(spacing: 3) {
                        Text("Yield").font(.system(size: 11, weight: .semibold))
                        Text("DELETE").font(.system(size: 8, design: .monospaced))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(ConsoleButtonStyle())
                .disabled(app.isPaused || app.trainingComplete)
                .accessibilityIdentifier("action.yield")
                .help("Pass this exchange. Useful when maintaining parity.")
            }

            HStack(spacing: 10) {
                if let phaseTag = commitmentPhaseTag {
                    Text(phaseTag.label)
                        .font(.system(size: 8, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(phaseTag.color)
                        .accessibilityIdentifier("match.commitmentPhase")
                }
                Text(feedbackLine)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(feedbackColor)
                    .lineLimit(1)
                    .accessibilityIdentifier("match.feedback")
                Spacer(minLength: 0)
                // Segment 18 — persistent, compact camera hint so the
                // orbit/pan/zoom gestures are discoverable without opening
                // the Controls sheet. Dimmed so it never competes with the
                // feedback line or the action buttons during play.
                Text(ControlsOverlay.cameraHintLabel)
                    .font(.system(size: 8, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(GameTheme.muted.opacity(0.6))
                    .accessibilityIdentifier("match.camera.hint")
                Button("Reset View") { app.resetCamera() }
                    .buttonStyle(ConsoleButtonStyle(accent: GameTheme.teal))
                    .accessibilityIdentifier("match.resetCamera")
                    .help("Restore the default camera angle.")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(GameTheme.panel)
        .overlay(alignment: .top) { GameTheme.teal.opacity(0.3).frame(height: 1) }
    }

    private func actionButton(_ action: AppState.BoardAction) -> some View {
        let projection = app.actionProjection(action)
        let isPreviewing = app.previewAction == action
        return Button { app.performBoardAction(action) } label: {
            VStack(spacing: 3) {
                Text(action.title).font(.system(size: 11, weight: .semibold))
                HStack(spacing: 5) {
                    Text(action.keyHint.uppercased())
                    Text("· \(projection.cost)")
                }
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(GameTheme.muted)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(isPreviewing && projection.legal ? GameTheme.gold.opacity(0.12) : .clear)
        }
        .buttonStyle(ConsoleButtonStyle(accent: projection.legal ? GameTheme.gold : GameTheme.muted))
        .disabled(!projection.legal || app.isPaused || app.trainingComplete)
        .accessibilityIdentifier("action.\(action.rawValue)")
        .help(projection.legal ? "\(action.title) · \(projection.cost) flux" : "\(action.title): \(reasonLabel(projection.reason)). Select a suitable node or link.")
        .onHover { hovering in
            if hovering { app.setActionPreview(action) }
            else if app.previewAction == action { app.clearActionPreview() }
        }
    }

    private var targetPickers: some View {
        HStack(spacing: 18) {
            HStack {
                Text("LINK").font(.system(size: 9, design: .monospaced))
                Picker("Link target", selection: $app.selectedEdgeId) {
                    Text("Choose link").tag(Optional<String>.none)
                    ForEach(app.availableEdges, id: \.id) { edge in
                        Text("\(nodeLabel(edge.u)) ↔ \(nodeLabel(edge.v))").tag(Optional(edge.id))
                    }
                }.labelsHidden()
            }
            HStack {
                Text("REGION").font(.system(size: 9, design: .monospaced))
                Picker("Region target", selection: $app.selectedFaceId) {
                    Text("Choose region").tag(Optional<String>.none)
                    ForEach(app.availableFaces, id: \.id) { face in
                        Text(face.id.replacingOccurrences(of: "F_", with: "")).tag(Optional(face.id))
                    }
                }.labelsHidden()
            }
        }
        .foregroundStyle(GameTheme.muted)
        .font(.system(size: 10, design: .monospaced))
    }

    private var pauseOverlay: some View {
        ZStack {
            Color.black.opacity(0.64).ignoresSafeArea()
            VStack(spacing: 18) {
                Text("EXCHANGE SUSPENDED")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(GameTheme.teal)
                Text("Paused")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(GameTheme.ink)
                Text("The board is held. Resume when you’re ready.")
                    .font(.system(size: 12))
                    .foregroundStyle(GameTheme.muted)
                HStack(spacing: 10) {
                    Button("Resume · Esc") { app.pauseToggle() }
                        .accessibilityIdentifier("pause.resume")
                    Button("Controls") { openHelp() }
                    Button("Main Menu") { app.showMenu() }
                }.buttonStyle(ConsoleButtonStyle(accent: GameTheme.gold))
            }
            .padding(38)
            .background(GameTheme.panel)
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(GameTheme.teal.opacity(0.45)) }
        }
    }

    private var completionOverlay: some View {
        ZStack {
            Color.black.opacity(0.68).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "checkmark.seal").font(.system(size: 34)).foregroundStyle(GameTheme.teal)
                Text("Lesson complete").font(.system(size: 30, weight: .light))
                Text("\(app.trainingLessonTitle) · \(app.trainingMoveCount) moves · par \(app.trainingParMoves)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(GameTheme.muted)
                HStack(spacing: 10) {
                    if let nextLesson {
                        Button("Next lesson") { app.startTrainingLesson(nextLesson) }
                            .accessibilityIdentifier("lesson.next")
                    }
                    if let lesson = app.currentLesson {
                        Button("Try again") { app.startTrainingLesson(lesson) }
                            .accessibilityIdentifier("lesson.retry")
                    }
                    Button("Academy") { app.showTraining() }
                        .accessibilityIdentifier("lesson.academy")
                    Button("Menu") { app.showMenu() }
                        .accessibilityIdentifier("lesson.menu")
                }.buttonStyle(ConsoleButtonStyle(accent: GameTheme.gold))
            }
            .padding(36)
            .background(GameTheme.panel)
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(GameTheme.teal.opacity(0.45)) }
        }
    }

    // Segment 20 — `internal` (not `private`) so the in-process screenshot
    // harness can mount the real Controls overlay surface (including the
    // Camera section) for deterministic PNG capture without AX. The sheet is
    // still presented identically in production via the `.sheet` modifier below;
    // only the access level changed.
    internal var controlsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("CONTROL INTERFACE").font(.system(size: 9, design: .monospaced)).tracking(3).foregroundStyle(GameTheme.teal)
                    Text("Your hands on the board").font(.system(size: 26, weight: .light))
                }
                Spacer()
                Button("Done") { showsHelp = false }.keyboardShortcut(.cancelAction)
                    .buttonStyle(ConsoleButtonStyle(accent: GameTheme.gold))
            }
            Text("Claim nodes. Forge links. Close regions. Or keep the contest balanced in Standoff.")
                .font(.system(size: 13)).foregroundStyle(GameTheme.muted)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 11) {
                    helpRow("CLICK / ARROWS", "Select a ring. Selection never spends your turn.")
                    helpRow("1–6 / TAB", "Select a plane. Shift-Tab goes back.")
                    helpRow("SPACE", "Pulse the selected node.")
                    helpRow("U · I · O", "Forge a link · Traverse a conduit · Seal a region.")
                    helpRow("P · ; · H · Y", "Reinforce · Sever · Counter · Feint.")
                    helpRow("DELETE", "Yield this exchange.")
                    helpRow("ESC / ⌘P", "Pause or resume. ⌘M returns to the menu.")
                    Divider()
                    // Segment 18 — Camera section so the restored orbit/pan/zoom
                    // gestures and the Reset View button are discoverable from
                    // the Controls overlay, not only from the transient console
                    // feedback line.
                    Text(ControlsOverlay.cameraSectionHeading).font(.system(size: 13, weight: .semibold)).foregroundStyle(GameTheme.gold)
                        .accessibilityIdentifier("controls.camera.heading")
                    Text(ControlsOverlay.cameraSectionSummary)
                        .font(.system(size: 12)).foregroundStyle(GameTheme.muted)
                    ForEach(ControlsOverlay.cameraHelpRows, id: \.key) { row in
                        helpRow(row.key, row.detail)
                    }
                    Divider()
                    Text("Mouse-only play").font(.system(size: 13, weight: .semibold)).foregroundStyle(GameTheme.gold)
                    Text("Select a ring, then use the action buttons below the board. Open Link / region targets to choose the connection or region you want. Dimmed actions are not legal at the current target; hover for the reason.")
                        .font(.system(size: 12)).foregroundStyle(GameTheme.muted)
                    Text("Two-handed chords").font(.system(size: 13, weight: .semibold)).foregroundStyle(GameTheme.gold)
                    Text("Hold Q/W/E/R for the row, A/S/D/F for the column, and J/K/L for the plane, then press an action. Choose a source ring first for link actions. Release the chord before your next move.")
                        .font(.system(size: 12)).foregroundStyle(GameTheme.muted)
                    if app.currentLesson != nil {
                        Divider()
                        Text("Lesson hint").font(.system(size: 13, weight: .semibold)).foregroundStyle(GameTheme.teal)
                        Text(GameTheme.readable(app.trainingHint, board: app.board)).font(.system(size: 12)).foregroundStyle(GameTheme.ink)
                    }
                }
            }
            .frame(maxHeight: 420)
            Text("Rules are an original playable interpretation. The television episode does not specify a complete ruleset.")
                .font(.system(size: 10)).foregroundStyle(GameTheme.muted)
        }
        .padding(28)
        .frame(width: 620)
        .background(GameTheme.background)
        .preferredColorScheme(.dark)
    }

    internal func helpRow(_ key: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(key).font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(GameTheme.gold).frame(width: 130, alignment: .leading)
            Text(detail).font(.system(size: 12)).foregroundStyle(GameTheme.ink)
        }
    }

    private func openHelp() {
        wasPausedBeforeHelp = app.isPaused
        if !app.isPaused { app.pauseToggle() }
        app.releaseBoardInput()
        showsHelp = true
    }

    private func closeHelp() {
        if !wasPausedBeforeHelp && app.isPaused { app.pauseToggle() }
        app.releaseBoardInput()
    }

    private var selectedPlateau: Int? { app.selectedNodeId.flatMap { app.board.nodeMap[$0]?.plateau } }

    /// Console feedback line. A live action/gesture preview takes precedence
    /// over the resting hint so the player sees what a hovered action would do
    /// before committing; a visible commitment window follows; the latest
    /// committed/rejected result otherwise shows.
    private var feedbackLine: String {
        if let preview = app.previewAction {
            let projection = app.actionProjection(preview)
            if projection.legal {
                return "Preview · \(preview.title) · \(projection.cost) flux — click or press \(preview.keyHint) to commit"
            }
            return "Preview · \(preview.title) — \(reasonLabel(projection.reason))"
        }
        if let window = app.commitmentWindow {
            let phaseTag = window.phase == .locked ? "LOCKED"
                         : window.phase == .resolving ? "RESOLVING" : "RESOLVED"
            return "Commit · \(window.label) · \(phaseTag)"
        }
        return app.actionFeedback.isEmpty
            ? "Click a ring or use arrows. Option-drag or right-drag orbits · Shift+Option-drag pans · scroll zooms."
            : GameTheme.readable(app.actionFeedback, board: app.board)
    }

    private var feedbackColor: Color {
        if app.previewAction != nil { return GameTheme.teal }
        if let window = app.commitmentWindow {
            return window.phase == .resolved ? GameTheme.muted
                 : window.action == .yield ? GameTheme.lavender
                 : GameTheme.gold
        }
        return app.actionFeedback.hasPrefix("✗") ? GameTheme.red : GameTheme.muted
    }

    // MARK: - Segment 10 — duel feel readouts

    /// The opponent-status label under the tick counter. In solo modes this
    /// reflects the bot's visible thinking state; in hot-seat it reflects the
    /// waiting player's input phase.
    private var opponentStatusLabel: String {
        if app.currentLesson != nil { return "ACADEMY" }
        if app.screen == .hotseat {
            return app.opponentTempo == .deliberating ? "AWAITING" : "EXCHANGES"
        }
        return app.opponentTempo.caption
    }

    private var opponentStatusColor: Color {
        switch app.opponentTempo {
        case .deliberating: return GameTheme.lavender
        case .committed:    return GameTheme.gold
        case .reacting:     return GameTheme.teal
        case .idle:         return GameTheme.muted
        }
    }

    /// The tactical tempo chip label (e.g. "BALANCED", "PRESSURED").
    private var tempoChipLabel: String {
        let tempo = app.tacticalTempo
        return tempo.label.caption
    }

    /// The tempo chip color, mapped from the tempo label.
    private var tempoChipColor: Color {
        switch app.tacticalTempo.label {
        case .surging:    return GameTheme.teal
        case .balanced:   return GameTheme.muted
        case .pressured:  return GameTheme.gold
        case .struggling: return GameTheme.red
        }
    }

    // MARK: - Segment 11 — feedback pulse + commitment phase HUD polish

    /// The latest feedback-pulse caption chip (e.g. "PULSE·P1", "SEVER·P2").
    /// Reads "—" before any action resolves so the chip is always present.
    private var pulseChipLabel: String {
        guard let pulse = app.lastFeedbackPulse else { return "—" }
        return "\(pulse.caption)·\(pulse.player.label)"
    }

    /// The pulse chip color, routed by player so the accent matches the board.
    private var pulseChipColor: Color {
        guard let pulse = app.lastFeedbackPulse else { return GameTheme.muted.opacity(0.5) }
        switch pulse {
        case .reject:                  return GameTheme.red
        case .yield:                   return GameTheme.lavender
        case .sever:                   return GameTheme.red
        default: return pulse.player == .player1 ? GameTheme.gold : GameTheme.red
        }
    }

    /// A commitment-phase tag shown beside the feedback line while a window is
    /// open. nil when no commitment is active so the line stays uncluttered.
    private var commitmentPhaseTag: (label: String, color: Color)? {
        guard let window = app.commitmentWindow else { return nil }
        switch window.phase {
        case .locked:
            return ("LOCKED", window.action == .yield ? GameTheme.lavender : GameTheme.gold)
        case .resolving:
            return ("RESOLVING", GameTheme.teal)
        case .resolved:
            return ("RESOLVED", GameTheme.muted)
        }
    }

    private func selectPlane(_ index: Int) {
        guard !app.isPaused && !app.trainingComplete else { return }
        let current = app.selectedNodeId.flatMap { app.board.nodeMap[$0] }
        let node = app.board.nodes.first { $0.plateau == index && $0.x == current?.x && $0.y == current?.y }
            ?? app.board.nodes.first { $0.plateau == index }
        if let node { app.selectBoardNode(node.id) }
    }

    private func nodeLabel(_ id: String?) -> String {
        guard let id, let node = app.board.nodeMap[id] else { return "SELECT A NODE" }
        let column = UnicodeScalar(65 + node.x).map { String(Character($0)) } ?? "\(node.x)"
        return "\(node.plateau + 1) / \(column)\(node.y + 1)"
    }

    private func reasonLabel(_ reason: RejectionReason?) -> String {
        guard let reason else { return "choose a target" }
        switch reason {
        case .insufficientFlux: return "not enough flux"
        case .notAdjacent: return "target is not adjacent"
        case .notOwnedByPlayer: return "source is not yours"
        case .notEnemyOwned: return "requires an enemy link"
        case .edgeSevered: return "link is severed"
        case .noCandidateCycle, .cycleBroken: return "complete the region’s links first"
        case .cycleAlreadySealed: return "region already sealed"
        case .counterWindowExpired: return "no matching recent enemy action"
        case .notAnAnchor: return "requires your anchor or fully charged node"
        default: return "unavailable at this target"
        }
    }

    private var nextLesson: TrainingLesson? {
        guard let id = app.currentLesson?.id,
              let index = TrainingCatalog.lessons.firstIndex(where: { $0.id == id }),
              TrainingCatalog.lessons.indices.contains(index + 1) else { return nil }
        return TrainingCatalog.lessons[index + 1]
    }
}
