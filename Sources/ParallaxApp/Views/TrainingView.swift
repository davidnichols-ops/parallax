import SwiftUI
import TacticalCore

/// Training Academy: browse solvable lessons, launch one, and see completion.
/// The lesson catalog comes from TacticalCore.TrainingCatalog (academy agent).
/// The shell only renders the catalog and calls startTrainingLesson(_:).
///
/// Segment 15 — surfaces Segment 14's persisted training progress and
/// in-progress lesson save/resume in the Academy UI:
/// - Completed-lesson checkmarks on each lesson row.
/// - Best-moves readout on each lesson row and in the detail panel.
/// - A "Continue Lesson" banner when a saved in-progress lesson exists,
///   wired to `AppState.resumeSavedLesson()`, with a non-destructive
///   "Discard" entry point wired to `AppState.discardSavedLesson()`.
/// - A progress summary ("N/M completed") in the sidebar header.
/// - Polished, accessible labels and identifiers on every new control.
public struct TrainingView: View {
    @ObservedObject var app: AppState
    @State private var selectedLessonId: String? = TrainingCatalog.lessons.first?.id

    public init(app: AppState) { self.app = app }

    public var body: some View {
        HStack(spacing: 0) {
            // Lesson catalog sidebar
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("TRAINING ACADEMY")
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                    // Segment 15 — progress summary, derived from persisted
                    // training progress so it stays in sync after restart.
                    Text(progressSummaryText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("training.progressSummary")
                        .accessibilityLabel(progressSummaryLabel)
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                // Segment 15 — "Continue Lesson" banner. Appears only when a
                // saved in-progress lesson exists. Continue resumes it;
                // Discard clears the save non-destructively (completed
                // lessons and best-moves are untouched).
                if let info = app.savedLessonInfo {
                    continueLessonBanner(info)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                }

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(TrainingCatalog.lessons) { lesson in
                            lessonRow(lesson)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 20)
                }
                .frame(maxHeight: .infinity)

                Divider()

                HStack {
                    Button("Back to Menu") { app.showMenu() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("training.back")
                    Spacer()
                }
                .padding(12)
            }
            .frame(width: 320)
            .frame(maxHeight: .infinity)
            .background(Color(red: 0.06, green: 0.07, blue: 0.10))

            // Lesson detail panel
            if let lesson = selectedLesson {
                lessonDetail(lesson)
            } else {
                VStack {
                    Spacer()
                    Text("Select a lesson to begin")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.04, green: 0.05, blue: 0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
        .preferredColorScheme(.dark)
    }

    // MARK: - Progress summary

    /// "3/8 completed" — the count of completed catalog lessons over total.
    private var progressSummaryText: String {
        "\(app.completedLessonCount)/\(app.totalLessonCount) completed"
    }

    /// A full voiceover-friendly label for the progress summary.
    private var progressSummaryLabel: String {
        let done = app.completedLessonCount
        let total = app.totalLessonCount
        if done == total {
            return "Training progress: all \(total) lessons completed."
        } else if done == 0 {
            return "Training progress: \(total) lessons available, none completed yet."
        } else {
            return "Training progress: \(done) of \(total) lessons completed."
        }
    }

    // MARK: - Continue Lesson banner

    /// The "Continue Lesson" banner shown when a saved in-progress lesson
    /// exists. Continue resumes the lesson (navigates to the match screen);
    /// Discard clears the save without affecting completed-lesson progress.
    private func continueLessonBanner(_ info: AppState.SavedLessonInfo) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                Text("LESSON IN PROGRESS")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
            }
            Text(info.title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Text("Move \(info.moveCount) of \(info.parMoves) (par)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    _ = app.resumeSavedLesson()
                } label: {
                    Label("Continue Lesson", systemImage: "play.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1.0, green: 0.55, blue: 0.15))
                .accessibilityIdentifier("training.continue")
                .accessibilityLabel("Continue lesson \(info.title), move \(info.moveCount) of \(info.parMoves)")

                Button {
                    app.discardSavedLesson()
                } label: {
                    Text("Discard")
                        .font(.system(size: 11, design: .monospaced))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("training.discard")
                .accessibilityLabel("Discard saved progress for \(info.title). Completed lessons and best moves are kept.")
                .help("Discard the saved in-progress lesson. Completed lessons and best moves are not affected.")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.10, green: 0.08, blue: 0.05))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(red: 1.0, green: 0.55, blue: 0.15).opacity(0.35))
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Lesson row

    private func lessonRow(_ lesson: TrainingLesson) -> some View {
        let isSelected = selectedLessonId == lesson.id
        let isCompleted = app.trainingProgress.isCompleted(lesson.id)
        let bestMoves = app.trainingProgress.bestMoves(for: lesson.id)
        return Button(action: { selectedLessonId = lesson.id }) {
            HStack(spacing: 10) {
                // Segment 15 — completion checkmark. Filled gold when
                // completed, a hollow circle placeholder otherwise, so the
                // progress state is visible at a glance.
                Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isCompleted
                        ? Color(red: 1.0, green: 0.82, blue: 0.42)
                        : Color.secondary.opacity(0.4))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(lesson.title)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isSelected ? .white : .primary)
                    // Segment 15 — best-moves readout under the title. Shows
                    // "Best: N" when completed, otherwise the par line.
                    if let best = bestMoves {
                        Text("Best: \(best) · Par: \(lesson.parMoves)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42).opacity(0.85))
                    } else {
                        Text("Par: \(lesson.parMoves) moves")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.white.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("training.lesson.\(lesson.id)")
        .accessibilityLabel(lessonRowLabel(lesson, isCompleted: isCompleted, bestMoves: bestMoves))
    }

    /// A descriptive voiceover label for a lesson row, including completion
    /// and best-moves state so the Academy is navigable without sight.
    private func lessonRowLabel(_ lesson: TrainingLesson,
                                isCompleted: Bool, bestMoves: Int?) -> String {
        var parts = [lesson.title, "par \(lesson.parMoves) moves"]
        if isCompleted, let best = bestMoves {
            parts.append("completed, best \(best) moves")
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Lesson detail

    private func lessonDetail(_ lesson: TrainingLesson) -> some View {
        let isCompleted = app.trainingProgress.isCompleted(lesson.id)
        let bestMoves = app.trainingProgress.bestMoves(for: lesson.id)
        return VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(lesson.title)
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                // Segment 15 — best-moves readout in the detail header.
                // Shows the par alongside the player's best when completed,
                // or just the par when not yet completed.
                if let best = bestMoves {
                    Text("Best: \(best) moves · Par: \(lesson.parMoves)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                        .accessibilityIdentifier("training.detail.bestMoves")
                        .accessibilityLabel("Your best: \(best) moves. Par: \(lesson.parMoves) moves.")
                } else {
                    Text("Par: \(lesson.parMoves) moves")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                        .accessibilityIdentifier("training.detail.bestMoves")
                        .accessibilityLabel("Not yet completed. Par: \(lesson.parMoves) moves.")
                }
                if isCompleted {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color(red: 1.0, green: 0.82, blue: 0.42))
                        .accessibilityIdentifier("training.detail.completedBadge")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Briefing", systemImage: "text.alignleft")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(GameTheme.readable(lesson.briefing, board: lesson.board))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Objective", systemImage: "target")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 1.0, green: 0.72, blue: 0.20))
                Text(GameTheme.readable(lesson.objective, board: lesson.board))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Hint", systemImage: "lightbulb")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.55, green: 0.78, blue: 0.95))
                Text(GameTheme.readable(lesson.hint, board: lesson.board))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Button("Back to Menu") { app.showMenu() }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("training.detail.back")
                Spacer()
                // Segment 15 — the Start button label reflects whether the
                // lesson has already been completed ("Practice Again" vs
                // "Start Lesson"), so the player understands the action.
                Button(isCompleted ? "Practice Again" : "Start Lesson") {
                    app.startTrainingLesson(lesson)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 1.0, green: 0.55, blue: 0.15))
                .accessibilityIdentifier("training.start")
                .accessibilityLabel(isCompleted
                    ? "Practice \(lesson.title) again"
                    : "Start lesson \(lesson.title)")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
    }

    private var selectedLesson: TrainingLesson? {
        guard let id = selectedLessonId else { return nil }
        return TrainingCatalog.lessons.first { $0.id == id }
    }
}
