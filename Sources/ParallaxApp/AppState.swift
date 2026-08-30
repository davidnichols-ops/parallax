import Foundation
import SwiftUI
import AppKit
import TacticalCore
import TacticalInput
import TacticalAudio
import TacticalHaptics
import TacticalBots
import TacticalPersistence
import TacticalNetworking
import TacticalRenderer

/// Central app state. Manages the game engine, bot, input, audio, persistence,
/// and navigation.
@MainActor
public final class AppState: ObservableObject {

    public enum Screen: Equatable {
        case menu
        case skirmish
        case standoff
        case hotseat
        case training
        case result
        case settings
        case replayTheater
        case replayPlayback
    }

    @Published public var screen: Screen = .menu
    @Published public var board: BoardDefinition = BoardFactory.triad()
    @Published public var engine: Engine = Engine(board: BoardFactory.triad(), matchSeed: 0xC0FFEE)
    @Published public var selectedNodeId: String? = nil
    @Published public var cameraResetToken: Int = 0
    @Published public var lastResult: MatchResult? = nil
    @Published public var matchSeed: UInt64 = 0xC0FFEE
    @Published public var tickRate: Double = 2.0
    @Published public var isPaused: Bool = false

    // Bot settings
    @Published public var botDifficulty: GrandmasterBot.Difficulty = .master
    @Published public var botPersonality: GrandmasterBot.Personality = .balanced
    /// Segment 12 — optional grandmaster duel persona id. Empty means "derive
    /// from botPersonality". Selectable independently so a player can pair any
    /// persona flavor with any personality weight set.
    @Published public var botPersonaId: String = ""
    @Published public var boardId: String = "triad"

    // Audio
    @Published public var sfxVolume: Float = 0.05
    @Published public var ambienceVolume: Float = 1.0
    @Published public var muted: Bool = false

    // Haptics — optional trackpad feedback for the fingertip duel feel.
    // Gated by enabled/muted/reduceMotion/availability inside HapticsEngine.
    @Published public var hapticsEnabled: Bool = true

    // Accessibility
    @Published public var reduceMotion: Bool = false
    @Published public var highContrast: Bool = false
    @Published public var colorVisionSafe: Bool = false
    @Published public var oneHandedMode: Bool = false

    // Replay
    @Published public var savedReplays: [URL] = []
    @Published public var currentReplay: Replay? = nil
    @Published public var replayBoard: BoardDefinition = BoardFactory.triad()
    @Published public var replayEngine: Engine? = nil
    @Published public var replayPosition: Int = 0
    @Published public var replayStatus: String = ""

    // Last move explanation
    @Published public var lastBotExplanation: String = ""
    @Published public var hotSeatActivePlayer: Player = .player1

    /// Transient legality/feedback line shown in the match HUD. Cleared on the
    /// next accepted action so the player always sees the latest result.
    @Published public var actionFeedback: String = ""
    /// Lightweight action/gesture preview: the board action the pointer is
    /// currently hovering, used to show a pre-commitment cue in the console
    /// and an optional alignment haptic. UI-only — never submits a command,
    /// never spends a turn, never mutates engine state.
    @Published public var previewAction: BoardAction? = nil
    /// True while the bot is thinking on a background task, so the HUD can show
    /// a "Bot thinking…" indicator instead of freezing the main thread.
    @Published public var botThinking: Bool = false

    // Segment 10 — rapid fingertip duel feel (UI-only, read-only vs engine).
    /// The active player's visible commitment window: the intent they have
    /// locked in, shown between queue and tick resolution. Cleared on stop.
    @Published public var commitmentWindow: CommitmentWindow? = nil
    /// The opponent's visible thinking state, derived from botThinking and the
    /// queued-command set. Drives the opponent-tempo chip in the HUD.
    @Published public var opponentTempo: OpponentTempo = .idle
    /// The latest transient feedback pulse (animation hook for the HUD/board).
    /// `feedbackPulseToken` increments on every new pulse so observers can
    /// re-trigger an animation even when the pulse value repeats.
    @Published public var lastFeedbackPulse: FeedbackPulse? = nil
    @Published public var feedbackPulseToken: Int = 0
    /// Segment 11 — monotonic token for the commitment window, incremented on
    /// every window change (open / phase transition / clear) so the renderer
    /// can re-apply the commitment glow on each phase. Companion to
    /// `feedbackPulseToken`.
    @Published public var commitmentWindowToken: Int = 0

    // Segment 12 — grandmaster duel persona layer (UI-only, read-only vs
    // engine). Companions to the Segment 10/11 tempo/commitment/pulse hooks:
    // they add the "what kind of thought" and "why this move" surfaces without
    // altering any existing hook, animation, or replay path.
    /// The active bot's resolved duel persona. Derived from `botPersonaId`
    /// (or `botPersonality` when the id is empty). Read-only vs the engine.
    @Published public var duelPersona: DuelPersona = .default
    /// The visible thinking phase for the bot's last chosen move — the
    /// "what kind of thought" companion to `opponentTempo` ("whether
    /// thinking"). nil until the first bot move resolves. Replay-safe: it is
    /// a pure function of (command, state, persona).
    @Published public var opponentThinkingPhase: ThinkingPhase? = nil
    /// A structured, replayable explanation of the bot's last move. Companion
    /// to `lastBotExplanation` (the plain string). Replay-safe: reconstructable
    /// from (command, state, persona) with no extra replay fields.
    @Published public var lastBotDecisionExplanation: DecisionExplanation? = nil

    // Training academy (lessons provided by TacticalCore.TrainingCatalog)
    @Published public var trainingBriefing: String = ""
    @Published public var trainingObjective: String = ""
    @Published public var trainingHint: String = ""
    @Published public var trainingParMoves: Int = 0
    @Published public var trainingMoveCount: Int = 0
    @Published public var trainingLessonTitle: String = ""
    @Published public var currentLesson: TrainingLesson? = nil
    @Published public var trainingComplete: Bool = false
    /// Segment 14 — persisted training progress (completed lessons + best
    /// move counts). Loaded on init, updated on lesson completion.
    @Published public var trainingProgress: PersistenceManager.TrainingProgress = .init()

    public let audio = AudioEngine()
    public var haptics = HapticsEngine()
    public let persistence: PersistenceManager

    private var bot: GrandmasterBot?
    private var inputParser: InputParser?
    private var tickTimer: Timer?
    private var currentReplayData: Replay?
    /// At most one intent per player is retained for the next simulation tick.
    /// This keeps local hot-seat play simultaneous instead of overwriting P1
    /// with P2's command before the tick resolves.
    private var queuedCommands: [Player: Command] = [:]

    /// Match-generation token. Rotated on every start/stop so a background bot
    /// search from a stopped or superseded match cannot apply its result to a
    /// new match. The detached search task captures this token and the expected
    /// engine tick/seed; applyBotResult rejects stale results.
    private var matchToken: UUID = UUID()
    /// Token for the currently in-flight bot search. Rotated on every new
    /// search so only the latest search's result is accepted.
    private var botSearchToken: UUID = UUID()
    private var botTask: Task<Void, Never>?
    private var inFlightHumanCommand: Command?
    private var matchActive = false
    private var lastMatchScreen: Screen = .skirmish
    private var playerSelections: [Player: String] = [:]

    public init() {
        self.persistence = PersistenceManager()
        try? BoardValidator.validate(board)
        loadPreferences()
        loadTrainingProgress()
    }

    /// Test initializer with an explicit haptics engine (e.g. one backed by a
    /// recording performer) so feedback routing can be asserted without firing
    /// real trackpad feedback. Loads preferences like the production init.
    internal init(haptics: HapticsEngine) {
        self.persistence = PersistenceManager()
        self.haptics = haptics
        try? BoardValidator.validate(board)
        loadPreferences()
        loadTrainingProgress()
    }

    /// Segment 15 — test initializer with an explicit haptics engine AND a
    /// custom persistence manager (e.g. one rooted at a temp directory) so
    /// training-progress and lesson-save round-trips can be verified through
    /// AppState without polluting the user's real App Support directory.
    internal init(haptics: HapticsEngine, persistence: PersistenceManager) {
        self.persistence = persistence
        self.haptics = haptics
        try? BoardValidator.validate(board)
        loadPreferences()
        loadTrainingProgress()
    }

    private func loadPreferences() {
        let prefs = persistence.loadPreferences()
        tickRate = prefs.tickRate
        botDifficulty = GrandmasterBot.Difficulty(rawValue: Int(prefs.botDifficulty) ?? 2) ?? .master
        botPersonality = GrandmasterBot.Personality(rawValue: prefs.botPersonality) ?? .balanced
        botPersonaId = prefs.botPersonaId
        boardId = prefs.preferredBoard
        sfxVolume = prefs.sfxVolume
        ambienceVolume = prefs.ambienceVolume
        muted = prefs.muted
        reduceMotion = prefs.reduceMotion
        highContrast = prefs.highContrast
        colorVisionSafe = prefs.colorVisionSafe
        oneHandedMode = prefs.oneHandedMode
        hapticsEnabled = prefs.hapticsEnabled
        audio.sfxVolume = sfxVolume
        audio.ambienceVolume = ambienceVolume
        audio.muted = muted
        syncHapticsSettings()
        resolveDuelPersona()
    }

    public func savePreferences() {
        var prefs = PersistenceManager.Preferences()
        prefs.tickRate = tickRate
        prefs.botDifficulty = String(botDifficulty.rawValue)
        prefs.botPersonality = botPersonality.rawValue
        prefs.botPersonaId = botPersonaId
        prefs.preferredBoard = boardId
        prefs.sfxVolume = sfxVolume
        prefs.ambienceVolume = ambienceVolume
        prefs.muted = muted
        prefs.reduceMotion = reduceMotion
        prefs.highContrast = highContrast
        prefs.colorVisionSafe = colorVisionSafe
        prefs.oneHandedMode = oneHandedMode
        prefs.hapticsEnabled = hapticsEnabled
        try? persistence.savePreferences(prefs)
    }

    // MARK: - Training progress (Segment 14)

    /// Load persisted training progress from disk. Called on init so the
    /// Academy shows completed lessons immediately after app launch.
    private func loadTrainingProgress() {
        trainingProgress = persistence.loadTrainingProgress()
    }

    /// Record a lesson completion in the persisted training progress and
    /// save to disk. Called from `resolveTick` when a lesson's predicate
    /// is satisfied.
    private func recordLessonCompletion(lessonId: String, moves: Int) {
        trainingProgress.recordCompletion(lessonId: lessonId, moves: moves)
        try? persistence.saveTrainingProgress(trainingProgress)
    }

    /// Save the current in-progress lesson state so it can be resumed after
    /// app restart or navigation away. Called from `stopMatch` when a lesson
    /// is in progress and not yet complete.
    private func saveInProgressLesson() {
        guard let lesson = currentLesson, !trainingComplete else { return }
        let counterable = engine.state.lastCounterableActions.isEmpty
            ? nil : engine.state.lastCounterableActions
        let state = PersistenceManager.LessonSaveState(
            lessonId: lesson.id,
            boardId: lesson.board.id,
            snapshot: engine.state.snapshot(),
            counterableActions: counterable,
            moveCount: trainingMoveCount,
            trainingComplete: trainingComplete
        )
        try? persistence.saveLessonState(state)
    }

    /// Resume a saved in-progress lesson. Returns true if a lesson was
    /// restored. The Academy UI can call this on launch to offer "Continue
    /// Lesson" when a save exists.
    @discardableResult
    public func resumeSavedLesson() -> Bool {
        guard let saved = persistence.loadLessonState(),
              let lesson = TrainingCatalog.lessons.first(where: { $0.id == saved.lessonId }),
              lesson.board.id == saved.boardId else {
            return false
        }
        stopMatch()
        matchActive = true
        self.board = lesson.board
        try? BoardValidator.validate(board)
        engine = saved.makeEngine(board: lesson.board)
        selectedNodeId = lesson.initialSelection
        bot = nil
        inputParser = InputParser(player: .player1, board: board)
        inputParser?.setCursorNodeId(lesson.initialSelection)
        queuedCommands = [:]
        lastBotExplanation = ""
        actionFeedback = lesson.briefing
        trainingBriefing = lesson.briefing
        trainingObjective = lesson.objective
        trainingHint = lesson.hint
        trainingParMoves = lesson.parMoves
        trainingMoveCount = saved.moveCount
        trainingLessonTitle = lesson.title
        currentLesson = lesson
        trainingComplete = saved.trainingComplete
        currentReplayData = Replay(lesson: lesson, engine: engine)
        screen = .skirmish
        isPaused = false
        audio.start()
        stopTickTimer()
        // Clear the save now that we've resumed — the next stopMatch will
        // write a fresh save if the lesson is still in progress.
        persistence.clearLessonState()
        return true
    }

    /// True if a saved in-progress lesson exists that can be resumed.
    public var hasSavedLesson: Bool {
        persistence.loadLessonState() != nil
    }

    /// Discard any saved in-progress lesson without resuming it.
    public func discardSavedLesson() {
        persistence.clearLessonState()
    }

    /// Segment 15 — a lightweight, UI-facing projection of the saved
    /// in-progress lesson so the Academy can show "Continue Lesson: <title>
    /// (move N)" without exposing the persistence layer to the view. Returns
    /// nil when no save exists or the saved lesson is no longer in the
    /// catalog (e.g. catalog changed across versions).
    public struct SavedLessonInfo: Hashable, Sendable {
        public let lessonId: String
        public let title: String
        public let moveCount: Int
        public let parMoves: Int

        public init(lessonId: String, title: String, moveCount: Int, parMoves: Int) {
            self.lessonId = lessonId
            self.title = title
            self.moveCount = moveCount
            self.parMoves = parMoves
        }
    }

    /// A UI-facing projection of the saved in-progress lesson, or nil when
    /// no save exists. The Academy reads this to render the "Continue Lesson"
    /// banner. Reads the save file each access (cheap, single small JSON).
    public var savedLessonInfo: SavedLessonInfo? {
        guard let saved = persistence.loadLessonState(),
              let lesson = TrainingCatalog.lessons.first(where: { $0.id == saved.lessonId }),
              lesson.board.id == saved.boardId else {
            return nil
        }
        return SavedLessonInfo(
            lessonId: lesson.id,
            title: lesson.title,
            moveCount: saved.moveCount,
            parMoves: lesson.parMoves
        )
    }

    /// Segment 15 — the number of completed lessons, for the Academy progress
    /// summary ("3/8 completed"). Derived from `trainingProgress` so it stays
    /// in sync with persisted state.
    public var completedLessonCount: Int {
        TrainingCatalog.lessons.filter { trainingProgress.isCompleted($0.id) }.count
    }

    /// Segment 15 — total lessons in the catalog, for the progress summary.
    public var totalLessonCount: Int { TrainingCatalog.lessons.count }

    // MARK: - Navigation

    public func showMenu() {
        stopMatch()
        screen = .menu
    }

    public func startSkirmish() {
        stopMatch()
        matchActive = true
        lastMatchScreen = .skirmish
        board = boardId == "grandmaster" ? BoardFactory.grandmaster() : BoardFactory.triad()
        try? BoardValidator.validate(board)
        engine = Engine(board: board, matchSeed: matchSeed)
        selectedNodeId = board.anchors.player1.first
        bot = GrandmasterBot(player: .player2, board: board, seed: matchSeed &+ 1,
                             difficulty: botDifficulty, personality: botPersonality)
        inputParser = InputParser(player: .player1, board: board)
        queuedCommands = [:]
        lastBotExplanation = ""
        resolveDuelPersona()
        opponentThinkingPhase = nil
        lastBotDecisionExplanation = nil
        currentReplayData = Replay(board: board, matchSeed: matchSeed,
                                   p1Type: .human, p2Type: .bot)
        // Segment 14: capture the bot persona id so replay playback can
        // reconstruct the persona HUD faithfully.
        currentReplayData?.player2PersonaId = botPersonaId
        screen = .skirmish
        isPaused = false
        audio.start()
        startTickTimer()
    }

    public func startStandoff() {
        stopMatch()
        matchActive = true
        lastMatchScreen = .standoff
        board = boardId == "grandmaster" ? BoardFactory.grandmaster() : BoardFactory.triad()
        try? BoardValidator.validate(board)
        engine = Engine(board: board, matchSeed: matchSeed)
        selectedNodeId = board.anchors.player1.first
        bot = GrandmasterBot(player: .player2, board: board, seed: matchSeed &+ 1,
                             difficulty: botDifficulty, personality: .standoff)
        inputParser = InputParser(player: .player1, board: board)
        queuedCommands = [:]
        lastBotExplanation = ""
        resolveDuelPersona()
        opponentThinkingPhase = nil
        lastBotDecisionExplanation = nil
        currentReplayData = Replay(board: board, matchSeed: matchSeed,
                                   p1Type: .human, p2Type: .bot)
        // Segment 14: capture the bot persona id for standoff replays.
        currentReplayData?.player2PersonaId = botPersonaId
        screen = .standoff
        isPaused = false
        audio.start()
        startTickTimer()
    }

    public func startHotSeat() {
        stopMatch()
        matchActive = true
        lastMatchScreen = .hotseat
        board = boardId == "grandmaster" ? BoardFactory.grandmaster() : BoardFactory.triad()
        try? BoardValidator.validate(board)
        engine = Engine(board: board, matchSeed: matchSeed)
        selectedNodeId = board.anchors.player1.first
        bot = nil  // No bot — both players are human
        inputParser = InputParser(player: .player1, board: board)
        hotSeatActivePlayer = .player1
        queuedCommands = [:]
        lastBotExplanation = ""
        currentReplayData = Replay(board: board, matchSeed: matchSeed,
                                   p1Type: .human, p2Type: .human)
        screen = .hotseat
        isPaused = false
        audio.start()
        // Hot-seat resolves only once both players have supplied an intent.
        // A timer here would silently convert missing input into yields.
        stopTickTimer()
    }

    public func showSettings() {
        stopMatch()
        screen = .settings
    }

    /// Show the training academy catalog browser. The lesson list comes from
    /// TacticalCore.TrainingCatalog (owned by the academy agent). The shell
    /// only renders the catalog and launches a chosen lesson.
    public func showTraining() {
        stopMatch()
        screen = .training
    }

    /// Launch a training lesson from its TrainingLesson definition. Uses the
    /// lesson's own makeEngine() so the configured starting position (owned
    /// nodes, flux, cursors) is preserved. Training replays ARE recorded in
    /// the v2 Replay format, which captures the lesson's initial snapshot and
    /// live counter-window state so the replay can be reconstructed and
    /// verified deterministically.
    public func startTrainingLesson(_ lesson: TrainingLesson) {
        stopMatch()
        matchActive = true
        self.board = lesson.board
        try? BoardValidator.validate(board)
        engine = lesson.makeEngine()
        selectedNodeId = lesson.initialSelection
        bot = nil
        inputParser = InputParser(player: .player1, board: board)
        inputParser?.setCursorNodeId(lesson.initialSelection)
        queuedCommands = [:]
        lastBotExplanation = ""
        actionFeedback = lesson.briefing
        trainingBriefing = lesson.briefing
        trainingObjective = lesson.objective
        trainingHint = lesson.hint
        trainingParMoves = lesson.parMoves
        trainingMoveCount = 0
        trainingLessonTitle = lesson.title
        currentLesson = lesson
        trainingComplete = false
        // Record training replays in v2 format (captures initial snapshot +
        // counterable actions for deterministic reconstruction).
        currentReplayData = Replay(lesson: lesson, engine: engine)
        screen = .skirmish
        isPaused = false
        audio.start()
        stopTickTimer()
    }

    /// Launch a training lesson from individual fields (legacy overload).
    public func startTrainingLesson(board: BoardDefinition, matchSeed: UInt64,
                                    initialSelection: String,
                                    title: String, briefing: String,
                                    objective: String, hint: String,
                                    parMoves: Int) {
        stopMatch()
        matchActive = true
        self.board = board
        try? BoardValidator.validate(board)
        engine = Engine(board: board, matchSeed: matchSeed)
        selectedNodeId = initialSelection
        bot = nil
        inputParser = InputParser(player: .player1, board: board)
        inputParser?.setCursorNodeId(initialSelection)
        queuedCommands = [:]
        lastBotExplanation = ""
        actionFeedback = briefing
        trainingBriefing = briefing
        trainingObjective = objective
        trainingHint = hint
        trainingParMoves = parMoves
        trainingMoveCount = 0
        trainingLessonTitle = title
        currentLesson = nil
        trainingComplete = false
        currentReplayData = Replay(board: board, matchSeed: matchSeed,
                                   p1Type: .human, p2Type: .human)
        screen = .skirmish
        isPaused = false
        audio.start()
        stopTickTimer()
    }

    public func showReplayTheater() {
        stopMatch()
        savedReplays = persistence.listReplays()
        replayStatus = ""
        screen = .replayTheater
    }

    public var replayTickCount: Int { currentReplay?.ticks.count ?? 0 }

    /// Opens a saved replay only after deterministic verification against its
    /// declared board and command stream. Replays are untrusted imported data.
    public func openReplay(_ url: URL) {
        do {
            let replay = try persistence.loadReplay(from: url)
            guard let replayBoard = boardDefinition(id: replay.boardId) else {
                replayStatus = "Unsupported replay board: \(replay.boardId)"
                return
            }
            guard replay.verify(board: replayBoard) else {
                replayStatus = "Replay integrity check failed — playback was not opened."
                return
            }

            currentReplay = replay
            self.replayBoard = replayBoard
            // Use makeReplayEngine so v2 training replays restore from their
            // captured initial snapshot + counterable actions.
            replayEngine = replay.makeReplayEngine(board: replayBoard)
            replayPosition = 0
            selectedNodeId = replayBoard.anchors.player1.first
            replayStatus = "Verified \(replay.durationTicks) ticks"
            screen = .replayPlayback
        } catch {
            replayStatus = "Could not read replay: \(error.localizedDescription)"
        }
    }

    public func stepReplayForward() {
        guard var replayEngine, let replay = currentReplay,
              replayPosition < replay.ticks.count else { return }
        let tick = replay.ticks[replayPosition]
        let commands = [
            tick.p1Command.toCommand(player: .player1),
            tick.p2Command.toCommand(player: .player2)
        ]
        let (snapshot, events) = replayEngine.submitTick(commands)
        guard CanonicalEncoding.snapshotHash(snapshot) == tick.snapshotHash else {
            replayStatus = "Playback stopped: snapshot mismatch at tick \(tick.tick)."
            return
        }
        self.replayEngine = replayEngine
        replayPosition += 1
        for event in events { playAudioForEvent(event) }
    }

    public func stepReplayBackward() {
        seekReplay(to: max(0, replayPosition - 1))
    }

    /// Reconstructs from the immutable replay stream. This is deliberately
    /// deterministic rather than attempting to reverse mutable game events.
    public func seekReplay(to position: Int) {
        guard let replay = currentReplay else { return }
        let target = max(0, min(position, replay.ticks.count))
        // Use makeReplayEngine so v2 training replays restore from their
        // captured initial snapshot + counterable actions.
        var nextEngine = replay.makeReplayEngine(board: replayBoard)
        for tick in replay.ticks.prefix(target) {
            let commands = [
                tick.p1Command.toCommand(player: .player1),
                tick.p2Command.toCommand(player: .player2)
            ]
            let (snapshot, _) = nextEngine.submitTick(commands)
            guard CanonicalEncoding.snapshotHash(snapshot) == tick.snapshotHash else {
                replayStatus = "Playback stopped: snapshot mismatch at tick \(tick.tick)."
                return
            }
        }
        replayEngine = nextEngine
        replayPosition = target
    }

    public func closeReplay() {
        replayEngine = nil
        currentReplay = nil
        replayPosition = 0
        showReplayTheater()
    }

    public func rematch() {
        matchSeed &+= 1
        // Preserve the match type: hot-seat stays hot-seat, standoff stays
        // standoff, everything else (skirmish/training) restarts as skirmish.
        if lastMatchScreen == .standoff { startStandoff() }
        else if lastMatchScreen == .hotseat { startHotSeat() }
        else { startSkirmish() }
    }

    // MARK: - Match loop

    private func startTickTimer() {
        stopTickTimer()
        let interval = 1.0 / (tickRate.isFinite ? min(10, max(0.5, tickRate)) : 2)
        tickTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.advanceTick()
            }
        }
    }

    private func stopTickTimer() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    public func stopMatch() {
        stopTickTimer()
        invalidateBotSearch(preserveIntent: false)
        audio.stop()
        // Segment 14: save in-progress lesson state before clearing it, so
        // the player can resume after navigation away or app restart. Only
        // saves if a lesson is active and not yet complete.
        saveInProgressLesson()
        queuedCommands = [:]
        playerSelections = [:]
        selectedEdgeId = nil
        selectedFaceId = nil
        actionFeedback = ""
        previewAction = nil
        matchActive = false
        isPaused = false
        inputParser?.reset()
        botThinking = false
        // Segment 10: clear duel-feel state so a stale commitment window or
        // opponent-tempo chip never carries into the next match.
        setCommitmentWindow(nil)
        opponentTempo = .idle
        lastFeedbackPulse = nil
        // Segment 12: clear persona observation state so a stale thinking phase
        // or decision explanation never carries into the next match.
        opponentThinkingPhase = nil
        lastBotDecisionExplanation = nil
        // Rotate the match token so any in-flight bot search is invalidated.
        matchToken = UUID()
        botSearchToken = UUID()
        // Clear training state when leaving a lesson.
        currentLesson = nil
        trainingLessonTitle = ""
        trainingBriefing = ""
        trainingObjective = ""
        trainingHint = ""
        trainingMoveCount = 0
        trainingComplete = false
    }

    public func pauseToggle() {
        guard isMatchScreen, !trainingComplete else { return }
        isPaused.toggle()
        invalidateBotSearch(preserveIntent: true)
        releaseBoardInput()
    }

    /// Cancels only this match's search. A paused intent is restored here,
    /// synchronously, never by a late callback from an obsolete match.
    private func invalidateBotSearch(preserveIntent: Bool) {
        botTask?.cancel()
        botTask = nil
        botSearchToken = UUID()
        if preserveIntent, let pending = inFlightHumanCommand,
           queuedCommands[pending.player] == nil {
            queuedCommands[pending.player] = pending
        }
        inFlightHumanCommand = nil
        botThinking = false
    }

    public func advanceTick() {
        guard isMatchScreen, !trainingComplete, !isPaused else { return }
        guard engine.state.gameStatus == .running else {
            if engine.state.gameStatus == .ended { finishMatch() }
            return
        }
        guard !botThinking else { return }
        if screen == .hotseat,
           (queuedCommands[.player1] == nil || queuedCommands[.player2] == nil) { return }

        let human = queuedCommands.removeValue(forKey: .player1) ?? .yield_(.player1)
        if let currentBot = bot {
            botThinking = true
            inFlightHumanCommand = human
            // Segment 10: the commitment window enters the resolving phase and
            // the opponent is visibly deliberating while the bot searches.
            if var window = commitmentWindow { window.phase = .resolving; setCommitmentWindow(window) }
            refreshOpponentTempo()
            let snapshot = engine.state
            let generation = matchToken
            let search = UUID()
            botSearchToken = search
            botTask = Task.detached(priority: .userInitiated) { [weak self] in
                guard !Task.isCancelled else { return }
                var searchingBot = currentBot
                let command = searchingBot.chooseCommand(state: snapshot)
                let explanation = searchingBot.explainMove(command, state: snapshot)
                guard !Task.isCancelled else { return }
                await self?.applyBotResult(
                    command: command, explanation: explanation, human: human,
                    updatedBot: searchingBot, generation: generation,
                    search: search, tick: snapshot.tick, seed: snapshot.matchSeed
                )
            }
        } else {
            let opponent = queuedCommands.removeValue(forKey: .player2) ?? .yield_(.player2)
            // Segment 10: hot-seat/training resolution enters the resolving phase.
            if var window = commitmentWindow { window.phase = .resolving; setCommitmentWindow(window) }
            refreshOpponentTempo()
            resolveTick(commands: [human, opponent])
        }
    }

    private func applyBotResult(command: Command, explanation: String, human: Command,
                                updatedBot: GrandmasterBot, generation: UUID,
                                search: UUID, tick: Int, seed: UInt64) {
        // A stale callback must make NO changes, including to the new match's
        // thinking indicator or command queue.
        guard generation == matchToken, search == botSearchToken,
              isMatchScreen, !isPaused, !trainingComplete,
              engine.state.gameStatus == .running, engine.state.tick == tick,
              engine.state.matchSeed == seed else { return }
        botTask = nil
        inFlightHumanCommand = nil
        botThinking = false
        bot = updatedBot
        lastBotExplanation = explanation
        // Segment 12: derive the visible thinking phase + replayable structured
        // explanation from the bot's chosen command against the pre-tick state
        // (the engine has not advanced — the tick/seed guards confirm it). Pure
        // observation; no engine mutation, no extra replay fields.
        duelPersona = updatedBot.duelPersona
        opponentThinkingPhase = updatedBot.thinkingPhase(for: command, state: engine.state)
        lastBotDecisionExplanation = updatedBot.structuredExplanation(for: command, state: engine.state)
        resolveTick(commands: [human, command])
    }

    /// Shared tick resolution + replay recording + audio + end detection.
    private func resolveTick(commands: [Command]) {
        let (snap, events) = engine.submitTick(commands)
        if currentLesson != nil,
           commands.first(where: { $0.player == .player1 })?.action != .select,
           !events.contains(where: { $0.player == .player1 && $0.type == .actionRejected }) {
            trainingMoveCount += 1
        }

        // Record replay tick for both regular matches and training lessons.
        // v2 training replays capture the lesson's initial snapshot, so
        // reconstruction is deterministic.
        currentReplayData?.recordTick(
            snap.tick, p1Cmd: commands[0], p2Cmd: commands[1],
            snapshotHash: CanonicalEncoding.snapshotHash(snap)
        )

        // Play audio for events
        for event in events {
            playAudioForEvent(event)
        }

        // Segment 10: map resolved events to feedback pulses (animation hooks)
        // and advance the commitment window to .resolved.
        emitFeedbackPulses(for: events)

        // Surface rejections that occurred during resolution as feedback.
        if let rejected = events.last(where: { $0.type == .actionRejected }) {
            let who = rejected.player == .player1 ? "P1" : "P2"
            actionFeedback = "\(who) action rejected by engine"
        }

        // Training lesson completion check — uses the lesson's own predicate.
        if let lesson = currentLesson,
           lesson.isComplete(state: engine.state, events: events) {
            trainingComplete = true
            actionFeedback = "✓ Lesson complete! (\(trainingMoveCount) moves, par \(trainingParMoves))"
            audio.playEvent(.matchEnded)
            stopTickTimer()
            // Finalize and save the training replay (v2 format).
            finalizeAndSaveReplay()
            // Segment 14: persist lesson completion progress (best moves).
            recordLessonCompletion(lessonId: lesson.id, moves: trainingMoveCount)
            // Clear any saved in-progress state — the lesson is done.
            persistence.clearLessonState()
        }

        if engine.state.gameStatus == .ended {
            finishMatch()
        }
    }

    public func submitPlayerCommand(_ cmd: Command) {
        // No actions on non-match screens or after training is complete.
        guard isMatchScreen, !trainingComplete else { return }
        // No actions while paused — the simulation is frozen.
        guard !isPaused else { return }
        guard cmd.player == activePlayer else { return }
        if cmd.action == .select {
            if let node = cmd.targetNodeId { selectBoardNode(node) }
            return
        }

        let resolved = CounterTargetResolver.resolve(
            cmd, counterableActions: engine.state.lastCounterableActions
        )
        // Pre-commit legality projection gives immediate descriptive feedback
        // before the tick resolves, so the player learns why an intent failed.
        let projection = Legality.project(resolved, state: engine.state)
        if projection.legal {
            actionFeedback = feedbackLabel(for: resolved)
            // Commitment feedback: a focused tactile accent the instant the
            // intent is queued, before the tick resolves. Only the six authored
            // fingertip cues fire; other actions stay silent.
            if let pattern = commitmentHaptic(for: resolved.action) {
                haptics.play(pattern)
            }
        } else {
            actionFeedback = "✗ \(actionLabel(for: resolved)) rejected: \(rejectionText(projection.reason))"
            audio.playEvent(.actionRejected)
            haptics.play(.rejection)
            // An illegal intent is not queued and does NOT hand off the turn.
            return
        }
        // A committed intent consumes the preview cue.
        previewAction = nil
        queuedCommands[resolved.player] = resolved
        // Segment 10: show the locked-in intent as a visible commitment window.
        recordCommitment(resolved)

        if screen == .hotseat {
            switchHotSeatPlayer()
            if queuedCommands[.player1] != nil && queuedCommands[.player2] != nil {
                advanceTick()
            }
        } else if currentLesson != nil, bot == nil {
            // Training lessons are solo: resolve immediately with P2 yielding so
            // the player sees the consequence of each action without a timer.
            queuedCommands[.player2] = .yield_(.player2)
            advanceTick()
        }
    }

    /// Human-readable action name for feedback.
    private func actionLabel(for cmd: Command) -> String {
        switch cmd.action {
        case .select:     return "Select"
        case .pulse:      return "Pulse"
        case .forge:      return "Forge"
        case .traverse:   return "Traverse"
        case .counter:    return "Counter"
        case .sever:      return "Sever"
        case .seal:       return "Seal"
        case .reinforce:  return "Reinforce"
        case .feint:      return "Feint"
        case .yield:      return "Yield"
        case .resign:     return "Resign"
        }
    }

    private func feedbackLabel(for cmd: Command) -> String {
        let name = actionLabel(for: cmd)
        switch cmd.action {
        case .select, .pulse, .reinforce, .feint:
            return "✓ \(name) → \(cmd.targetNodeId ?? "?")"
        case .forge, .traverse, .sever:
            return "✓ \(name) → \(cmd.targetEdgeId ?? "?")"
        case .seal:
            return "✓ \(name) → \(cmd.candidateCycleId ?? "?")"
        case .counter:
            return "✓ \(name) → seq \(cmd.counteredSeq.map(String.init) ?? "auto")"
        case .yield:  return "✓ Yield"
        case .resign: return "✓ Resign"
        }
    }

    private func rejectionText(_ reason: RejectionReason?) -> String {
        guard let reason else { return "not legal here" }
        switch reason {
        case .gameNotRunning:        return "game not running"
        case .insufficientFlux:      return "insufficient flux"
        case .invalidTarget:         return "invalid target"
        case .notOwnedByPlayer:      return "you don't own that node"
        case .notEnemyOwned:         return "not enemy-owned"
        case .edgeSevered:           return "edge is severed"
        case .conduitOccluded:       return "conduit occluded"
        case .notAdjacent:           return "not adjacent"
        case .counterWindowExpired:  return "counter window expired"
        case .noCandidateCycle:      return "no candidate cycle"
        case .cycleAlreadySealed:    return "cycle already sealed"
        case .cycleBroken:           return "cycle broken"
        case .illegalAction:         return "illegal action"
        case .notAnAnchor:           return "not an anchor"
        case .capacityContested:     return "capacity contested"
        }
    }

    private func switchHotSeatPlayer() {
        hotSeatActivePlayer = hotSeatActivePlayer == .player1 ? .player2 : .player1
        inputParser = InputParser(player: hotSeatActivePlayer, board: board)
        let selection = playerSelections[hotSeatActivePlayer]
            ?? Legality.cursorNodeId(engine.state, hotSeatActivePlayer)
        selectBoardNode(selection)
    }

    public func handleGameKey(_ key: Character, isDown: Bool) {
        guard let parser = inputParser else { return }
        if isDown {
            if let cmd = parser.keyDown(key) {
                submitPlayerCommand(cmd)
                if let nodeId = cmd.targetNodeId {
                    selectedNodeId = nodeId
                }
                audio.playEvent(.cursorMoved)
            }
        } else {
            parser.keyUp(key)
        }
    }

    /// The set of screens where a live match is in progress and gameplay input
    /// is accepted. Navigation to settings, academy, replay theater, or the
    /// main menu stops the match; input on those screens is ignored.
    private var isMatchScreen: Bool {
        matchActive && (screen == .skirmish || screen == .standoff || screen == .hotseat)
    }

    /// Mouse selection for the fixed tabletop board. Pointer selection is
    /// UI-only: it moves the visual cursor and synchronizes the input parser
    /// so a subsequent keyboard forge/sever targets the clicked node. It does
    /// NOT submit a game command and does NOT hand off the turn in hot-seat.
    public func selectBoardNode(_ nodeId: String) {
        guard !isPaused, !trainingComplete else { return }
        guard board.nodeMap[nodeId] != nil else { return }
        selectedNodeId = nodeId
        playerSelections[activePlayer] = nodeId
        // Clear stale edge/face selections so the control deck recomputes
        // targets incident to the newly selected node.
        selectedEdgeId = nil
        selectedFaceId = nil
        inputParser?.setCursorNodeId(nodeId)
    }

    /// The tabletop control deck offers mouse-first play in addition to the
    /// chorded keyboard. It uses the same command queue as every other input.
    public func pulseSelectedBoardNode() {
        let player: Player = screen == .hotseat ? hotSeatActivePlayer : .player1
        let fallback = player == .player1 ? board.anchors.player1.first : board.anchors.player2.first
        guard let target = selectedNodeId ?? fallback else { return }
        submitPlayerCommand(.pulse(player, target))
    }

    public func yieldBoardTurn() {
        let player: Player = screen == .hotseat ? hotSeatActivePlayer : .player1
        submitPlayerCommand(.yield_(player))
    }

    // MARK: - Mouse-first board action API (for main's UI control deck)

    /// Gameplay actions exposed to the mouse-first control deck. Each case maps
    /// to a real engine command path — no synthetic or bypassed submissions.
    public enum BoardAction: String, CaseIterable, Identifiable {
        case pulse, forge, traverse, seal, reinforce, sever, counter, feint

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .pulse: return "Pulse"
            case .forge: return "Forge"
            case .traverse: return "Traverse"
            case .seal: return "Seal"
            case .reinforce: return "Reinforce"
            case .sever: return "Sever"
            case .counter: return "Counter"
            case .feint: return "Feint"
            }
        }

        public var keyHint: String {
            switch self {
            case .pulse: return "Space"
            case .forge: return "U"
            case .traverse: return "I"
            case .seal: return "O"
            case .reinforce: return "P"
            case .sever: return ";"
            case .counter: return "H"
            case .feint: return "Y"
            }
        }
    }

    /// Currently selected edge for edge-targeted actions (forge/traverse/sever/
    /// counter). Set by the UI when the user picks an incident edge.
    @Published public var selectedEdgeId: String? = nil
    /// Currently selected face for seal. Set by the UI when the user picks a
    /// candidate face containing the selected node.
    @Published public var selectedFaceId: String? = nil

    /// The player whose input is currently active (hot-seat rotates; solo
    /// modes are always player 1).
    public var activePlayer: Player {
        screen == .hotseat ? hotSeatActivePlayer : .player1
    }

    /// Edges incident to the selected node, deterministically sorted by id.
    /// The UI offers these as forge/sever/traverse/counter targets.
    public var availableEdges: [EdgeDef] {
        guard let nodeId = selectedNodeId else { return [] }
        let inc = board.incidence[nodeId] ?? []
        return board.edges.filter { inc.contains($0.id) }.sorted { $0.id < $1.id }
    }

    /// Faces containing the selected node (any boundary edge is incident to
    /// it), deterministically sorted by id. The UI offers these as seal
    /// targets.
    public var availableFaces: [FaceDef] {
        guard let nodeId = selectedNodeId else { return [] }
        let inc = Set(board.incidence[nodeId] ?? [])
        return board.faces.filter { face in
            face.boundary.contains { inc.contains($0) }
        }.sorted { $0.id < $1.id }
    }

    /// Builds a real candidate command for `action` and projects its legality
    /// against the current engine state. Does NOT submit or mutate state.
    /// Reports the honest reason if the action is illegal — never pretends an
    /// unavailable target is legal.
    public func actionProjection(_ action: BoardAction) -> Projection {
        let cmd = candidateCommand(for: action)
        let resolved = CounterTargetResolver.resolve(
            cmd, counterableActions: engine.state.lastCounterableActions
        )
        return Legality.project(resolved, state: engine.state)
    }

    /// Resolves the selected edge/face (or a legal incident candidate) and
    /// submits the same real command path as keyboard input. On a node change
    /// the UI may choose another target via `selectedEdgeId`/`selectedFaceId`.
    public func performBoardAction(_ action: BoardAction) {
        let cmd = candidateCommand(for: action)
        let resolved = CounterTargetResolver.resolve(
            cmd, counterableActions: engine.state.lastCounterableActions
        )
        submitPlayerCommand(resolved)
    }

    /// Constructs a candidate command for the given board action, preferring
    /// the UI-selected edge/face, then falling back to a useful incident
    /// candidate. Missing targets remain missing, so legality reports the
    /// real error instead of silently turning an unavailable action into Yield.
    private func candidateCommand(for action: BoardAction) -> Command {
        let player = activePlayer
        let fallback = player == .player1 ? board.anchors.player1.first : board.anchors.player2.first
        let node = selectedNodeId ?? fallback
        switch action {
        case .pulse: return Command(player: player, action: .pulse, targetNodeId: node)
        case .reinforce: return Command(player: player, action: .reinforce, targetNodeId: node)
        case .feint: return Command(player: player, action: .feint, targetNodeId: node)
        case .seal:
            let choices = selectedFaceId.map { [$0] } ?? availableFaces.map(\.id)
            let commands = choices.map { Command.seal(player, $0) }
            return commands.first(where: { Legality.project($0, state: engine.state).legal })
                ?? commands.first ?? Command(player: player, action: .seal)
        case .forge, .traverse, .sever, .counter:
            let kind: ActionKind
            switch action {
            case .forge: kind = .forge
            case .traverse: kind = .traverse
            case .sever: kind = .sever
            default: kind = .counter
            }
            let choices: [String]
            if let selectedEdgeId {
                choices = [selectedEdgeId]
            } else {
                let eligible = availableEdges.filter {
                    action == .traverse ? $0.kind == .conduit : (action == .forge ? $0.kind == .intra : true)
                }
                // Prefer a new link to re-forging one already fully owned.
                choices = eligible.sorted {
                    let aOwned = engine.state.edges[$0.id]?.owner == player.owner
                    let bOwned = engine.state.edges[$1.id]?.owner == player.owner
                    if aOwned != bOwned { return !aOwned }
                    return $0.id < $1.id
                }.map(\.id)
            }
            let commands = choices.map {
                CounterTargetResolver.resolve(
                    Command(player: player, action: kind, targetEdgeId: $0),
                    counterableActions: engine.state.lastCounterableActions
                )
            }
            return commands.first(where: { Legality.project($0, state: engine.state).legal })
                ?? commands.first ?? Command(player: player, action: kind)
        }
    }

    /// Receives key events from the global window keyboard monitor (mounted by
    /// WindowInputBridge) or from a focused board view. Keeping gameplay input
    /// inside the game window prevents a terminal or unrelated SwiftUI control
    /// from swallowing movement chords.
    ///
    /// Contract (maos-shell-followup §4):
    /// - Command-modified shortcuts pass through to native menus (return false).
    /// - Escape PAUSES/RESUMES; resign is only via a deliberate UI button.
    /// - Arrow navigation and Return selection are UI-only (no command, no
    ///   hot-seat handoff, no engine snapshot mutation).
    /// - Tab no longer switches hot-seat players; it cycles panes (view-owned).
    /// - Unknown keys return false so they reach the responder chain.
    /// - Auto-repeat key-downs are ignored so game actions don't auto-fire.
    @discardableResult
    public func handleBoardKeyEvent(_ event: NSEvent, isDown: Bool) -> Bool {
        guard isMatchScreen else { return false }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            return false
        }
        let text = event.charactersIgnoringModifiers ?? ""
        guard let parser = inputParser else { return false }
        let navigationCodes: Set<UInt16> = [48, 53, 123, 124, 125, 126, 36, 76]
        if !isDown {
            for character in text { parser.keyUp(character) }
            return navigationCodes.contains(event.keyCode) || text.contains(where: parser.recognizes)
        }
        if event.keyCode == 53 {
            if !event.isARepeat { pauseToggle() }
            return true
        }
        guard !isPaused, !trainingComplete else { return false }

        if event.keyCode == 48 {
            cyclePlane(backwards: event.modifierFlags.contains(.shift))
            return true
        }
        if let number = Int(text), (1...6).contains(number) {
            selectPlane(number - 1)
            return true
        }
        let direction: (Int, Int)?
        switch event.keyCode {
        case 123: direction = (-1, 0)
        case 124: direction = (1, 0)
        case 125: direction = (0, -1)
        case 126: direction = (0, 1)
        default: direction = nil
        }
        if let (x, y) = direction {
            if let target = parser.navigateCursor(dx: x, dy: y) { selectBoardNode(target) }
            return true
        }
        if event.keyCode == 36 || event.keyCode == 76 {
            if let target = parser.selectCursor() { selectBoardNode(target) }
            return true
        }
        let recognized = text.contains(where: parser.recognizes)
        if event.isARepeat { return recognized }
        for character in text {
            // A one-key action uses the same useful candidate as its button.
            // A complete two-handed chord retains the explicitly held target.
            if parser.heldCoordinate == nil,
               let action = BoardAction.allCases.first(where: {
                   $0.keyHint.lowercased() == String(character).lowercased()
                       || ($0 == .pulse && character == " ")
               }) {
                performBoardAction(action)
            } else if let command = parser.keyDown(character) {
                if let target = command.targetNodeId { selectBoardNode(target) }
                submitPlayerCommand(command)
            }
        }
        return recognized
    }

    public func selectPlane(_ index: Int) {
        guard isMatchScreen, !isPaused, !trainingComplete else { return }
        let current = selectedNodeId.flatMap { board.nodeMap[$0] }
        let nodes = board.nodes.filter { $0.plateau == index }
        let target = nodes.first { $0.x == current?.x && $0.y == current?.y } ?? nodes.first
        if let target { selectBoardNode(target.id) }
    }

    private func cyclePlane(backwards: Bool) {
        let indices = board.plateaus.map(\.index).sorted()
        guard !indices.isEmpty else { return }
        let selected = selectedNodeId.flatMap { board.nodeMap[$0]?.plateau }
        let current = selected.flatMap { indices.firstIndex(of: $0) } ?? 0
        selectPlane(indices[(current + (backwards ? indices.count - 1 : 1)) % indices.count])
    }

    /// A lost focus event must release held chord keys, otherwise the next
    /// command can inherit stale row/column/plateau state.
    public func releaseBoardInput() {
        inputParser?.reset()
    }

    private func playAudioForEvent(_ event: Event) {
        switch event.type {
        case .nodePulsed: audio.playEvent(.nodePulsed, player: event.player)
        case .linkForged: audio.playEvent(.linkForged, player: event.player)
        case .cycleSealed: audio.playEvent(.cycleSealed, player: event.player)
        case .actionRejected: audio.playEvent(.actionRejected)
        case .scoreChanged: audio.playEvent(.scoreChanged)
        case .tickResolved: audio.playEvent(.tickResolved)
        case .linkSevered: audio.playEvent(.linkSevered)
        case .conduitTraversed: audio.playEvent(.conduitTraversed, player: event.player)
        case .vectorCountered: audio.playEvent(.vectorCountered, player: event.player)
        case .yieldIssued: audio.playEvent(.yieldIssued, player: event.player)
        default: break
        }
    }

    // MARK: - Match end

    /// Finalize the current replay (if any) with final hashes and save it.
    /// Shared by regular match end (`finishMatch`) and training lesson
    /// completion (`resolveTick`).
    private func finalizeAndSaveReplay() {
        let snap = engine.state.snapshot()
        let snapHash = CanonicalEncoding.snapshotHash(snap)
        let logHash = CanonicalEncoding.eventLogHash(engine.log)
        currentReplayData?.finalize(snapshotHash: snapHash, eventLogHash: logHash)
        if let replay = currentReplayData {
            _ = try? persistence.saveReplay(replay)
        }
    }

    private func finishMatch() {
        stopTickTimer()
        // Finalize and save the replay (shared with training lesson completion).
        finalizeAndSaveReplay()

        let snap = engine.state.snapshot()
        let snapHash = CanonicalEncoding.snapshotHash(snap)
        let logHash = CanonicalEncoding.eventLogHash(engine.log)
        let result = MatchResult(
            winner: snap.winner,
            endReason: snap.endReason,
            tick: snap.tick,
            p1Score: snap.player1State.score,
            p2Score: snap.player2State.score,
            p1Moves: snap.player1State.moves,
            p2Moves: snap.player2State.moves,
            p1Composure: snap.player1State.composure,
            p2Composure: snap.player2State.composure,
            eventCount: engine.log.events.count,
            snapshotHash: snapHash,
            eventLogHash: logHash
        )
        lastResult = result
        audio.playEvent(.matchEnded)
        haptics.play(.victory)
        screen = .result
    }

    public func resetCamera() {
        cameraResetToken &+= 1
    }

    private func boardDefinition(id: String) -> BoardDefinition? {
        switch id {
        case "triad": return BoardFactory.triad()
        case "grandmaster": return BoardFactory.grandmaster()
        default: return nil
        }
    }

    // MARK: - Settings updates

    public func updateAudioSettings() {
        audio.sfxVolume = sfxVolume
        audio.ambienceVolume = ambienceVolume
        audio.muted = muted
        // Mute is shared: silencing audio also silences the tactile channel so
        // a single "mute all" control covers both feedback surfaces.
        syncHapticsSettings()
        savePreferences()
    }

    /// Push the four haptic gates (enabled/muted/reduceMotion) into the engine.
    /// Called on preference load and whenever a gating setting changes.
    public func syncHapticsSettings() {
        haptics.enabled = hapticsEnabled
        haptics.muted = muted
        haptics.reduceMotion = reduceMotion
    }

    /// The authored commitment haptic for an action, or nil for actions outside
    /// the six fingertip cues (pulse/forge/sever/seal/counter/victory). Returns
    /// nil for select/yield/resign/traverse/reinforce/feint so haptics stay a
    /// focused tactile accent rather than a constant buzz.
    private func commitmentHaptic(for action: ActionKind) -> HapticsEngine.HapticPattern? {
        switch action {
        case .pulse:   return .pulse
        case .forge:   return .forge
        case .sever:   return .sever
        case .seal:    return .seal
        case .counter: return .counter
        default:       return nil
        }
    }

    // MARK: - Action/gesture preview

    /// Set the hovered board action as the live preview and fire a single light
    /// alignment haptic when the projected action is legal. UI-only: never
    /// submits a command, never spends a turn, never mutates engine state.
    public func setActionPreview(_ action: BoardAction?) {
        guard isMatchScreen, !isPaused, !trainingComplete else {
            previewAction = nil
            return
        }
        previewAction = action
        if let action, actionProjection(action).legal {
            haptics.play(.preview)
        }
    }

    /// Clear the preview (pointer left the control deck).
    public func clearActionPreview() {
        previewAction = nil
    }

    // MARK: - Segment 10 — duel feel (commitment window, tempo, feedback pulses)

    /// The active player's tactical tempo/debt, computed read-only from the
    /// current engine `PlayerState` fields. Pure; never mutates the engine.
    /// Returns a neutral `.balanced` tempo when no match is in progress.
    public var tacticalTempo: TacticalTempo {
        guard isMatchScreen,
              let active = engine.state.playerStates[activePlayer],
              let opp = engine.state.playerStates[activePlayer.opponent] else {
            return TacticalTempo(active: PlayerState(), opponent: PlayerState(), parity: 0)
        }
        return TacticalTempo(active: active, opponent: opp, parity: engine.state.parity)
    }

    /// Recompute the opponent's visible thinking state from the live flags.
    /// Called after every command queue/tick transition so the HUD chip stays
    /// honest. UI-only; never reads private bot internals.
    public func refreshOpponentTempo() {
        guard isMatchScreen else { opponentTempo = .idle; return }
        let opponent = activePlayer.opponent
        if botThinking {
            opponentTempo = .deliberating
        } else if queuedCommands[opponent] != nil {
            opponentTempo = .committed
        } else if screen == .hotseat, queuedCommands[activePlayer] != nil {
            // In hot-seat the waiting human is the "opponent" from the active
            // player's view; they have not yet committed.
            opponentTempo = .deliberating
        } else {
            opponentTempo = .idle
        }
    }

    /// Record a committed intent as a visible commitment window and refresh the
    /// opponent tempo. Called on the legal path of `submitPlayerCommand`.
    private func recordCommitment(_ cmd: Command) {
        setCommitmentWindow(CommitmentWindow(
            player: cmd.player,
            action: cmd.action,
            targetNode: cmd.targetNodeId,
            targetEdge: cmd.targetEdgeId,
            targetFace: cmd.candidateCycleId,
            phase: .locked,
            targetTick: engine.state.tick + 1
        ))
        refreshOpponentTempo()
    }

    /// Map resolved tick events to feedback pulses (animation hooks) and advance
    /// the commitment window to `.resolved`. Called once per tick in
    /// `resolveTick`. UI-only; never mutates engine state.
    private func emitFeedbackPulses(for events: [Event]) {
        // The last fingertip pulse wins so the HUD shows the most salient accent
        // of the exchange (e.g. a sever over a concurrent pulse).
        var lastPulse: FeedbackPulse? = nil
        for event in events {
            if let pulse = FeedbackPulse.from(event) {
                lastPulse = pulse
            }
        }
        if let pulse = lastPulse {
            lastFeedbackPulse = pulse
            feedbackPulseToken &+= 1
        }
        // Advance the commitment window to resolved so the HUD holds the result.
        if var window = commitmentWindow {
            window = CommitmentWindow(
                player: window.player, action: window.action,
                targetNode: window.targetNode, targetEdge: window.targetEdge,
                targetFace: window.targetFace, phase: .resolved,
                targetTick: window.targetTick
            )
            setCommitmentWindow(window)
        }
        refreshOpponentTempo()
    }

    /// Centralized commitment-window setter that also bumps
    /// `commitmentWindowToken` whenever the window actually changes, so the
    /// renderer can re-apply the commitment glow on open/phase/clear. No-op
    /// when the new value equals the current value.
    private func setCommitmentWindow(_ window: CommitmentWindow?) {
        guard commitmentWindow != window else { return }
        commitmentWindow = window
        commitmentWindowToken &+= 1
    }

    // MARK: - Segment 11 — renderer-observable duel-feel mappers

    /// The current feedback pulse mapped to the renderer's observation type,
    /// carrying the monotonic `feedbackPulseToken`. nil when no pulse has fired
    /// yet. The renderer fires a board accent only when this token changes.
    public var boardFeedbackPulse: BoardFeedbackPulse? {
        guard let pulse = lastFeedbackPulse else { return nil }
        let kind: BoardFeedbackPulse.Kind
        var node: String? = nil, edge: String? = nil, face: String? = nil
        switch pulse {
        case .pulse(let id, _):        kind = .pulse;     node = id
        case .forge(let id, _):        kind = .forge;     edge = id
        case .sever(let id, _):        kind = .sever;     edge = id
        case .seal(let id, _):         kind = .seal;      face = id
        case .counter(let id, _):      kind = .counter;   edge = id
        case .traverse(let id, _):     kind = .traverse;  edge = id
        case .yield:                   kind = .yield
        case .reject:                  kind = .reject
        case .contested(let id, _):    kind = .contested; node = id
        }
        return BoardFeedbackPulse(kind: kind, player: pulse.player,
                                  targetNode: node, targetEdge: edge,
                                  targetFace: face, token: feedbackPulseToken)
    }

    /// The current commitment window mapped to the renderer's observation type,
    /// carrying the monotonic `commitmentWindowToken`. nil when no window is
    /// open. The renderer attaches a glow on the target while locked/resolving
    /// and fades it when the phase reaches `.resolved`.
    public var boardCommitmentGlow: BoardCommitmentGlow? {
        guard let window = commitmentWindow else { return nil }
        let phase: BoardCommitmentGlow.Phase
        switch window.phase {
        case .locked:    phase = .locked
        case .resolving: phase = .resolving
        case .resolved:  phase = .resolved
        }
        return BoardCommitmentGlow(player: window.player,
                                   targetNode: window.targetNode,
                                   targetEdge: window.targetEdge,
                                   targetFace: window.targetFace,
                                   phase: phase, token: commitmentWindowToken)
    }

    // MARK: - Segment 12 — grandmaster duel persona observation

    /// Resolve the active duel persona from `botPersonaId`, falling back to the
    /// persona derived from `botPersonality` when the id is empty. Called on
    /// preference load and match start so the HUD reads a consistent persona.
    /// Pure setter; never mutates the engine.
    public func resolveDuelPersona() {
        duelPersona = botPersonaId.isEmpty
            ? DuelPersona.from(personality: botPersonality)
            : DuelPersona.resolve(botPersonaId)
    }

    /// The bot's coarse adaptive label at the current state (EASING / STEADY /
    /// PRESSING). Returns `.holding` when no bot is present (hot-seat/training)
    /// or outside a match. Pure read of the engine state; never mutates it.
    public var opponentAdaptation: AdaptiveDifficulty.Adaptation {
        guard isMatchScreen, let bot else { return .holding }
        return bot.adaptiveLabel(at: engine.state)
    }

    /// The deliberation vocabulary line for the current thinking phase, or nil
    /// when no bot move has resolved yet. Drives the "what the opponent is
    /// thinking" HUD cue (companion to the Segment 10 `opponentTempo` chip).
    public var opponentDeliberationLine: String? {
        guard let phase = opponentThinkingPhase else { return nil }
        return duelPersona.deliberationLine(for: phase)
    }
}

public struct MatchResult: Identifiable, Equatable {
    public let id = UUID()
    public let winner: Player?
    public let endReason: Snapshot.EndReason?
    public let tick: Int
    public let p1Score: Int
    public let p2Score: Int
    public let p1Moves: Int
    public let p2Moves: Int
    public let p1Composure: Int
    public let p2Composure: Int
    public let eventCount: Int
    public let snapshotHash: String
    public let eventLogHash: String
}
