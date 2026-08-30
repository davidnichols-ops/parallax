# Parallax — Strategema recreation

A native macOS strategy game inspired by the holographic table in *Star Trek: The Next Generation*, “Peak Performance.” Upright translucent planes, green circuitry, lavender/chartreuse fields, red/yellow markers, a perforated rectangular projector, and fingertip sensors recreate its visual language. The board is a live 3D scene: drag or right-drag to orbit, Option-Shift-drag to pan, scroll to zoom, and press the in-match **Reset View** button to restore the default elevated, slanted angle.

This is an independent fan recreation with original rules, geometry, and synthesized audio—not an official Star Trek product. Television stills are development references, not bundled assets. The episode does not specify a complete playable ruleset.

Copyright © 2026 David Nichols. All rights reserved. See [LICENSE](LICENSE) and [content and attribution](docs/licensing-and-attribution.md).

## Run

Open the DMG, drag **Parallax.app** to **Applications**, then launch it from Finder. Do not run the executable inside the app from Terminal.

Choose **Training academy** for eight lessons, **Enter the arena** for solo play, **Standoff** for a parity-focused opponent, or **Local duel** for two people sharing the Mac.

The current local release is for Apple silicon, macOS 14 or newer. It is ad-hoc signed, not Developer ID signed or notarized. Public distribution requires an Apple signing identity and notarization; see [docs/release-readiness.md](docs/release-readiness.md) for the full public-release checklist.

### Opening an ad-hoc signed build

Because the app is ad-hoc signed (not Developer ID), Gatekeeper will block a direct double-click launch on a Mac with default settings. Use one of:

- **Right-click → Open** — In Finder, right-click (or Control-click) **Parallax.app** → **Open**, then click **Open** in the Gatekeeper dialog. This creates a one-time launch exception.
- **Remove quarantine** — `xattr -dr com.apple.quarantine /Applications/Parallax.app` removes the quarantine flag so the app launches normally. Use this only for builds you trust.

A Developer ID signed and notarized build would not require either step.

## Controls

- Click a ring or use arrows to select a node. Selection never spends a turn.
- **Space** pulses the selected node.
- **1–6** chooses a plane; **Tab / Shift-Tab** cycles planes.
- **U** forges, **I** traverses, **O** seals.
- **P** reinforces, **;** severs, **H** counters, **Y** feints.
- **Delete / Backspace** yields.
- **Escape / ⌘P** pauses or resumes. **⌘M** returns to the menu.
- Menu, Pause, Controls, and the action bar remain visible in the game window.
- Mouse-only play uses the same action buttons. Open **Link / region targets** to choose an explicit target. Disabled actions explain their reason on hover.
- Advanced chords: hold **Q/W/E/R** for a row, **A/S/D/F** for a column, **J/K/L** for a plane, then an action. Link chords use the selected node as source.
- **Camera:** drag or right-drag orbits, **Option-Shift-drag** pans, **scroll** zooms, and the in-match **Reset View** button restores the default angle. The console shows a compact `DRAG·ORBIT  ⌥⇧·PAN  SCROLL·ZOOM` hint, and the Controls sheet lists the same gestures under a Camera section.

In a local duel, both players submit an action before the exchange resolves. In solo play, a background bot search keeps the main interface responsive. Pausing preserves a queued human action and invalidates stale bot results.

## Included

- Three-plane Triad and six-plane Grandmaster boards.
- Solo, Standoff, local two-player play, and eight solvable academy lessons.
- Capture, forge, traverse, seal, reinforce, sever, counter, feint, and yield.
- Deterministic resolution, replay verification/stepping/seeking, and local preferences.
- Grandmaster duel opponents with authored personas, visible thinking text, bluff/feint cues, adaptive difficulty, and replayable move explanations.
- Commitment windows with opponent thinking states, tactical tempo, and transient board/HUD feedback pulses (burst/flash/ripple) on every action.
- Training academy progress tracking: per-lesson completion, best move count, completed-lesson count, and a Continue/Discard banner for an in-progress lesson saved across app restarts.
- SceneKit graphics, native SwiftUI/AppKit controls, original synthesized sound, reduced-motion and contrast options.
- App/DMG packaging with an original icon, resource manifest, signature checks, image verification, and recoverable previous outputs.

There is no production online matchmaking, hosted backend, or controller support. Mid-lesson save/resume is supported for academy lessons (counter-window state persists across app restarts); skirmish and duel sessions are not mid-match savable. Training lessons are recorded and replayed in the versioned replay format (v2), which captures each lesson's authored initial snapshot, live counter-window state, and player persona ids for deterministic reconstruction. Networking modules are experimental, not a finished online mode.

## Build and verify

Use Xcode’s Swift 6 toolchain on macOS:

~~~bash
swift test -j 2
./Scripts/build-release.sh --version 2.1.0-rc5 --output ./dist
./Scripts/verify-bundle.sh ./dist/Parallax.app
/bin/bash Scripts/test-build-release.sh
~~~

The release script builds current source by default. The --skip-build option is for packaging tests, not checking whether source changes reached a release. The optional --scratch-path selects a separate build cache. The script supports macOS Bash 3.2 and reports missing option arguments without the old unbound-array crash.

Public distribution requires --sign "Developer ID Application: …" --notarize --notary-profile NAME with your credentials. No signing credentials are stored in this project.

For real offscreen board renders and non-black-pixel checks:

~~~bash
swift run parallax-render-check triad /tmp/parallax-triad.png 1200 600
swift run parallax-render-check grandmaster /tmp/parallax-grandmaster.png 1200 600
~~~

These verify the actual SceneKit scene, not desktop interaction. Input tests, geometry/picking tests, and live UI checks are separate.

## Source map

- Sources/TacticalCore: deterministic rules, boards, state, academy lessons.
- Sources/TacticalRenderer: active SceneKit board, framing, picking; legacy Metal utilities remain tested.
- Sources/ParallaxApp: app state, native views, window-scoped keyboard routing.
- Sources/TacticalInput: two-handed chord parser.
- Sources/TacticalAudio: bounded, restart-safe synthesized audio.
- Sources/TacticalBots: deterministic opponents.
- Sources/TacticalPersistence: preferences and replays.
- Sources/TacticalNetworking: experimental networking, not a finished service.
- Scripts: app/DMG assembly, icon generation, packaging checks.
- docs/rulebook.md: original playable rules.

## References and size

The visual direction uses the [episode observations and stills from Ex Astris Scientia](https://www.ex-astris-scientia.org/observations/peakperformance.htm). No episode video, actor images, franchise music, or extracted proprietary game assets are included.

This is not a multi-gigabyte asset production. The board and sound are generated from code; shipped size is measured rather than padded. See the release inventory alongside the final DMG for actual bytes and checksums.
