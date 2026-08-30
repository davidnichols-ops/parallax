import SwiftUI
import TacticalBots

/// Settings view — controls, audio, accessibility, bot difficulty.
public struct SettingsView: View {
    @ObservedObject var app: AppState

    public init(app: AppState) { self.app = app }

    public var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Settings")
                    .font(.system(size: 28, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)

                // Match
                section("Match") {
                    HStack {
                        Text("Tick Rate").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Slider(value: $app.tickRate, in: 0.5...10, step: 0.5)
                            .onChange(of: app.tickRate) { _, _ in app.savePreferences() }
                        Text(String(format: "%.1f t/s", app.tickRate))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white)
                            .frame(width: 60)
                    }
                    HStack {
                        Text("Bot Difficulty").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $app.botDifficulty) {
                            Text("Novice").tag(GrandmasterBot.Difficulty.novice)
                            Text("Adept").tag(GrandmasterBot.Difficulty.adept)
                            Text("Master").tag(GrandmasterBot.Difficulty.master)
                            Text("Grandmaster").tag(GrandmasterBot.Difficulty.grandmaster)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .onChange(of: app.botDifficulty) { _, _ in app.savePreferences() }
                    }
                    HStack {
                        Text("Bot Personality").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: $app.botPersonality) {
                            Text("Aggressive").tag(GrandmasterBot.Personality.aggressive)
                            Text("Defensive").tag(GrandmasterBot.Personality.defensive)
                            Text("Balanced").tag(GrandmasterBot.Personality.balanced)
                            Text("Standoff").tag(GrandmasterBot.Personality.standoff)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 300)
                        .onChange(of: app.botPersonality) { _, _ in
                            app.savePreferences()
                            // Re-resolve the persona so a personality change
                            // updates the derived persona when no explicit
                            // persona id is set. Pure setter; no engine effect.
                            app.resolveDuelPersona()
                        }
                        .accessibilityIdentifier("settings.botPersonality")
                    }
                    // Segment 13 — bot persona picker. Independent of the
                    // personality weight set so a player can pair any persona
                    // flavor with any eval personality. "Auto" (empty id)
                    // derives the persona from the selected personality, which
                    // is the default and backward-compatible behavior.
                    HStack {
                        Text("Bot Persona").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Spacer()
                        Picker("", selection: personaPickerBinding) {
                            Text("Auto").tag(PersonaPickerTag.auto)
                            ForEach(DuelPersona.catalog, id: \.id) { persona in
                                Text(persona.displayName).tag(PersonaPickerTag.id(persona.id))
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(width: 300)
                        .accessibilityIdentifier("settings.botPersona")
                        .accessibilityLabel("Bot persona. Auto derives from personality.")
                    }
                }

                // Audio
                section("Audio") {
                    HStack {
                        Text("SFX Volume").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Slider(value: $app.sfxVolume, in: 0...1, step: 0.05)
                            .onChange(of: app.sfxVolume) { _, _ in app.updateAudioSettings() }
                        Text(String(format: "%.0f%%", app.sfxVolume * 100))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white).frame(width: 50)
                    }
                    HStack {
                        Text("Ambience Volume").font(.system(size: 13, design: .monospaced)).foregroundStyle(.secondary)
                        Slider(value: $app.ambienceVolume, in: 0...1, step: 0.05)
                            .onChange(of: app.ambienceVolume) { _, _ in app.updateAudioSettings() }
                        Text(String(format: "%.0f%%", app.ambienceVolume * 100))
                            .font(.system(size: 13, design: .monospaced)).foregroundStyle(.white).frame(width: 50)
                    }
                    Toggle("Mute All Audio", isOn: $app.muted)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: app.muted) { _, _ in app.updateAudioSettings() }
                        .accessibilityIdentifier("settings.mute")
                    Toggle("Trackpad Haptics", isOn: $app.hapticsEnabled)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: app.hapticsEnabled) { _, _ in
                            app.syncHapticsSettings()
                            app.savePreferences()
                        }
                        .help("Tactile cues for pulse, forge, sever, seal, counter, and victory. Silenced by Mute All Audio and Reduce Motion.")
                        .accessibilityIdentifier("settings.haptics")
                }

                // Accessibility
                section("Accessibility") {
                    Toggle("Reduce Motion", isOn: $app.reduceMotion)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: app.reduceMotion) { _, _ in
                            app.syncHapticsSettings()
                            app.savePreferences()
                        }
                        .accessibilityIdentifier("settings.reduceMotion")
                    Toggle("High Contrast", isOn: $app.highContrast)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: app.highContrast) { _, _ in app.savePreferences() }
                        .accessibilityIdentifier("settings.highContrast")
                    Toggle("Color-Vision-Safe Palette", isOn: $app.colorVisionSafe)
                        .font(.system(size: 13, design: .monospaced))
                        .onChange(of: app.colorVisionSafe) { _, _ in app.savePreferences() }
                        .accessibilityIdentifier("settings.colorVisionSafe")
                    Text("Mouse-only and one-handed play are always available: use the action bar, arrow keys, and plane buttons.")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }

                // Controls reference
                section("Controls") {
                    VStack(alignment: .leading, spacing: 6) {
                        controlRow("Click / Arrows", "Select a node without spending a turn")
                        controlRow("1–6 / Tab", "Choose a plane (Shift-Tab goes back)")
                        controlRow("Escape / ⌘P", "Pause or resume")
                        controlRow("Q W E R", "Row 0-3 (left hand)")
                        controlRow("A S D F", "Column 0-3 (left hand)")
                        controlRow("J K L", "Plateau 0-2 (right hand)")
                        controlRow("Space", "Pulse (capture node)")
                        controlRow("Enter", "Select (move cursor)")
                        controlRow("U", "Forge (create link)")
                        controlRow("I", "Traverse conduit")
                        controlRow("O", "Seal (close cycle)")
                        controlRow("P", "Reinforce anchor")
                        controlRow(";", "Sever (cut enemy edge)")
                        controlRow("H", "Counter the matching enemy vector")
                        controlRow("Y", "Feint at an adjacent node")
                        controlRow("Backspace", "Yield (skip turn)")
                        controlRow("⌘R", "Reset camera")
                        controlRow("Drag", "Orbit camera")
                        controlRow("Scroll", "Zoom")
                        controlRow("Opt+Drag", "Pan")
                    }
                }

                Button("Back to Menu") { app.showMenu() }
                    .buttonStyle(.borderedProminent)
                    .padding(.bottom, 20)
                    .accessibilityIdentifier("settings.back")
            }
            .padding()
            .frame(maxWidth: 600)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.04, green: 0.05, blue: 0.08))
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
            content()
        }
        .padding(16)
        .background(Color.white.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }

    private func controlRow(_ key: String, _ desc: String) -> some View {
        HStack {
            Text(key).font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.white).frame(width: 120, alignment: .leading)
            Text(desc).font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Segment 13 — bot persona picker support

    /// Picker tag that distinguishes "Auto" (derive from personality) from an
    /// explicit persona id. Equatable/Hashable so it can back a Picker
    /// selection. The empty-string `botPersonaId` maps to `.auto`.
    private enum PersonaPickerTag: Hashable {
        case auto
        case id(String)

        /// The `botPersonaId` to write back to AppState when this tag is
        /// selected. `.auto` → "" (the backward-compatible default).
        var personaId: String {
            switch self {
            case .auto:       return ""
            case .id(let id): return id
            }
        }
    }

    /// The picker selection derived from the current `botPersonaId`. Empty id
    /// → `.auto`; any other id → `.id(id)`. A computed binding so the picker
    /// always reflects the persisted state without a separate @State mirror.
    /// The setter writes the persona id back to AppState, persists it, and
    /// re-resolves the active persona so the HUD reads the new flavor on the
    /// next match.
    private var personaPickerBinding: Binding<PersonaPickerTag> {
        Binding(
            get: { app.botPersonaId.isEmpty ? .auto : .id(app.botPersonaId) },
            set: { newValue in
                app.botPersonaId = newValue.personaId
                app.savePreferences()
                app.resolveDuelPersona()
            }
        )
    }
}
