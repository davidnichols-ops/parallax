# Prototype Audit — `strategema (1).html`

**Audited by:** direct read of `/Users/david/Downloads/strategema (1).html` (3,883 lines, 130 KB).
**Method:** every claim below is tied to a line range in the source. No claim is made from memory or from the master prompt's assertions without code confirmation.

## 1. What the prototype actually is

A single self-contained HTML file. It loads **Three.js r128 from a CDN** (`cdnjs.cloudflare.com`, line 8) and defines three JavaScript modules in inline `<script>` tags:

| Module | Lines | Role |
|---|---|---|
| `StrategemaEngine` | 445–1745 | First simulation engine (`class Engine`) |
| `StrategemaView` | 1747–2958 | Three.js 3D renderer + Web Audio synthesizer + 2D Canvas "finger HUD" |
| `StrategemaAI` | 2960–3701 | Second engine (`StrategemaGameEngine`) + `KolramiAI`/`DataAI`/`RikerAI` + `LcarsUiController` |
| Master orchestrator | 3703–3883 | Wires DOM buttons, keyboard, AI `setInterval` loop |

There is **no backend, no build system, no packaging, no `package.json`, no server**. It is a browser-only artifact. Running it requires an internet connection for the Three.js CDN.

## 2. Board, nodes, and edges (as implemented)

- **One inline Canvas/WebGL board**, rendered by Three.js into `#three-canvas` (line 372). A separate 2D Canvas `#finger-hud-canvas` (line 251) draws stylized hands.
- **48 nodes on three 4×4 plateaus** (lines 490–491, 679–703): `GRID_SIZE = 4`, `TOTAL_NODES = 48`, layers named Alpha/Beta/Gamma (lines 484–488). Nodes are addressed `L{layer}_X{x}_Y{y}` (line 554).
- **Intra-plateau edges**: horizontal + vertical grid neighbors, 24 per plateau × 3 = 72 (lines 706–754).
- **Inter-plateau conduits** at 6 coordinate pairs — the 4 corners `(0,0),(0,3),(3,0),(3,3)` plus centers `(1,1),(2,2)` (lines 526–533). For each, three conduit edges are created: Alpha↔Beta, Beta↔Gamma, and a direct Alpha↔Gamma "vortex" (lines 757–816). That is 6 × 3 = 18 conduit edges. Total edges ≈ 90 (header comment line 455).
- **Seeded anchors**: P1 owns `L0_X0_Y0` and `L2_X0_Y3`; P2 owns `L0_X3_Y3` and `L2_X3_Y0`, each locked at energy 100 (lines 819–847).

## 3. Advertised input scheme (as mapped in `handleKeyDown`, lines 1556–1639)

| Hand | Keys | Action |
|---|---|---|
| Left | `Q W E R` | select row 0–3 |
| Left | `A S D F` | select column 0–3 |
| Left | `Space` | Neural Burst (omni pulse from cursor) |
| Right | `J K L` | shift to plateau Alpha/Beta/Gamma |
| Right | `;` / `:` | sever an enemy edge around the cursor |
| Right | `U I O P` | conduit jump to gates NW/NE/SW/SE, target layer = `(activeLayer+1)%3` |
| Right | `Enter` | seal enclosure |
| Either | arrow keys | pulse from cursor in that direction |

The on-page "Tactical Briefing" modal and the finger HUD advertise this layout. `J K L` plateaus and `U I O P` conduits are labeled in the HUD.

## 4. HUDs and modes (as rendered)

- **HUDs** (lines 374–401): per-player `FLUX: <n>%` bar, `DOMINANCE: <n.n>%`, a center `TACTICAL MOVE TICKER` (5-digit `move-counter`), and a `KOLRAMI IMPATIENCE: <n>%` tilt gauge.
- **Mode buttons** (lines 362–366): `VS Kolrami`, `Ten-Forward Standoff`, `2-Player Duel`, plus `Tactical Briefing` and `Audio: ON`.
- **Audio**: a procedural Web Audio synthesizer (lines 1795–2958) with ambient drone, vector-pulse chimes, sever sweep, layer-shift whoosh, stalemate harmony, neural-burst sub drop. All synthesized; no external audio assets.

## 5. Confirmed defects (each verified against source)

These are the master prompt's claimed defects, confirmed or refined against the actual code.

### 5.1 The active AI is random
**Confirmed.** The master orchestrator's `runAITurn` (lines 3757–3773) picks `rndLayer`, `rndCol`, `rndRow` each via `Math.floor(Math.random() * …)` and calls `engine.pulseVector(2, rndLayer, rndCol, rndRow)` (or `engine.crossPlateauConduit(2, …)` with 25% probability). There is **no heuristic, no search, no evaluation**. The elaborate `KolramiAI.computeMove` (lines 3208–3256) and `DataAI.computeMove` (lines 3282–3349) classes live in the *separate* `StrategemaAI` module and are **never invoked** by the orchestrator.

### 5.2 PvP is nonfunctional
**Confirmed.** In 2-Player mode the button handler (lines 3856–3864) sets `aiOpponent = null` and clears `aiTimer`. But the keyboard handler (lines 3815–3819) always calls `engine.handleKeyboardInput(e.code, true)` — a single hard-coded `true` argument. There is **no second-player key map, no turn ownership, no input isolation**. Player 2 has no way to move. The "2-Player Duel" label is cosmetic.

### 5.3 Conduits are tactically inert
**Confirmed (refined).** `conduitJump` (lines 1226–1291) *does* mechanically flip the conduit edge's owner to the caller, set flux to 100, capture the target node if unlocked, and move the cursor. So the edge exists and changes state. However:
- No **capacity**, **ownership pressure**, **traversal cost beyond a flat 12 flux**, **occlusion handling**, or **tactical value** — it is a flat ownership flip.
- The AI's conduit path calls `engine.crossPlateauConduit(2, (rndLayer+1)%3)` (line 3768), a method that **does not exist** on `StrategemaEngine.Engine` (which exposes `conduitJump(playerId, gate, targetLayer)`). This call would throw at runtime, so the AI conduit branch is broken in practice.
- The advertised `U I O P` gates only cover the 4 corner conduits; the 2 center conduits (`C1`,`C2`) have no key binding (lines 1612–1619).

### 5.4 Sever only meaningfully increments impatience
**Confirmed (refined).** `severEdge` (lines 1159–1203) does set `edge.isSevered = true`, `edge.cooldown = 45`, `edge.owner = 'NEUTRAL'`, `edge.flux = 0`. So it is not *purely* cosmetic. But:
- There is **no propagation** through connectivity, supply, or territory. Severed edges simply come back after 45 ticks (`tick`, lines 1656–1666).
- The only *visible* systemic effect is that `severEdge` calls `_recordParityEvent` (line 1189), which increments `stalemate.streak` and `kolramiImpatience`. So the player-observable consequence of severing is driving the impatience gauge, not reshaping the graph.
- `severAroundCursor` (lines 1209–1218) severs only the **first** enemy edge found around the cursor, with no targeting UI.

### 5.5 Enter duplicates / overlaps pulse
**Refined.** In `handleKeyDown` (line 1622–1624) `Enter`/`Return` maps to `sealEnclosure`, *not* pulse. However the orchestrator invokes `engine.handleKeyboardInput(e.code, true)` — a method **not present** on `StrategemaEngine.Engine` (which exposes `handleKeyDown`). The orchestrator's actual key→action mapping is therefore against an API that doesn't match the shipped engine class, so the runtime behavior of Enter is indeterminate from this file alone. The visible `handleKeyDown` mapping has overlapping concepts (Space = burst, Enter = seal, arrows = pulse) with no documented precedence.

### 5.6 Flux is not a live economy
**Confirmed.** Flux regeneration happens only inside `tick(deltaMs)` (lines 1645–1674). The master orchestrator **never calls `tick()`** — its only interval is `setInterval(runAITurn, 250)` (line 3777). There is no per-frame tick loop. Consequently:
- Regeneration never occurs during play.
- Costs *are* applied on actions (`PULSE=5`, `BURST=28`, `SEVER=15`, `CONDUIT=12`, `SEAL=10`, lines 536–542), so flux would drain, not stay static — but the HUD's persistent `FLUX: 100%` (lines 380–383) reflects the initial value and the absence of a regen loop makes the displayed number unreliable as an economy signal.
- There is **no projection of cost before commitment, no tactical debt, no cap on hoarding beyond the hard 100 ceiling, and no relationship between flux and stable networks/sectors**.

### 5.7 Enemy nodes can be overwritten
**Confirmed.** In `pulseVector` (lines 1023–1031): `if (target.owner !== playerId && !target.isLocked) { target.energy += 35; if (target.energy >= 100 || target.owner === 'NEUTRAL') { target.owner = playerId; … } }`. A neutral node is captured in one pulse; an enemy node is captured once accumulated energy crosses 100. `executeNeuralBurst` (lines 1128–1131) overwrites neighbor ownership outright (`target.owner = playerId`) unless `isLocked`. There is no contest resolution, no defender priority, no supply requirement.

### 5.8 Mode changes do not restart the AI loop
**Confirmed (refined).** The three mode buttons (lines 3838–3864) each call `engine.reset()`, `scene3D.syncWithEngine(engine)`, and `updateTelemetry()`. So the *board* resets. However:
- Only the **begin-game** button (line 3826–3832) calls `startAILoop()`. The `VS Kolrami` and `Ten-Forward Standoff` buttons do **not** call `startAILoop()`. So after visiting 2-Player mode (which clears `aiTimer`) and switching back to Kolrami/Standoff, the AI is silent until the page is reloaded.
- `gameMode` is written but **never read** by the engine or the AI loop — `runAITurn` behaves identically in `KOLRAMI` and `STANDOFF` modes. The only mode-specific logic (`STANDOFF_SURVIVAL` fast-forward, lines 3521–3528) lives in the *unused* `StrategemaGameEngine` class.

### 5.9 No backend or packaging exists
**Confirmed.** No server code, no networking, no persistence, no build script, no `.app`, no `Info.plist`, no signing. The artifact is a single HTML file dependent on a CDN.

## 6. Additional structural problems found during audit

1. **Two divergent engines.** `StrategemaEngine.Engine` (lines 584–1724) and `StrategemaAI.StrategemaGameEngine` (lines 3407–3566) define **incompatible** board representations (string IDs `L0_X0_Y0` vs `ALPHA_0_0`), owner encodings (strings `'PLAYER_1'` vs integers `OWNER.PLAYER_1=1`), and method names. Only the first is instantiated by the orchestrator (line 3708); the second is dead code.
2. **Orchestrator/engine API mismatch.** The orchestrator calls `engine.state.winner` (line 3758), `engine.crossPlateauConduit(2, l, layer)` (line 3768), `engine.pulseVector(2, layer, col, row)` (line 3770), `engine.handleKeyboardInput(code, true)` (line 3818), `engine.getState()` (line 3782), `engine.onMove`/`engine.onEnclosure`/etc. (lines 3718–3749). The shipped `StrategemaEngine.Engine` exposes `getGameState()`, `handleKeyDown(key, playerId)`, `pulseVector(playerId, sourceNodeId, targetNodeId)`, `conduitJump(playerId, gate, targetLayer)`, and an `on(event, cb)` listener registry — **none of the orchestrator's calls match**. The prototype as shipped is internally inconsistent and will throw on most interactions.
3. **Nondeterminism.** `Date.now()` is written into every event (line 1698); `Math.random()` drives the AI (lines 3763–3767) and tie-breaking in `KolramiAI.computeMove` (line 3236). There is no seed, no state hash, no replay encoding.
4. **Enclosure = 2×2 corner painting.** `_detectAndSealEnclosures` (lines 1339–1408) seals a cell iff all 4 edges of a 2×2 square are owned by the same player and not severed. This is generic grid-cycle painting, not territory derived from an authored embedding; cross-plateau cycles and irregular faces are not modeled.
5. **Win condition is raw node count.** `_checkWinConditions` (lines 1509–1521) ends the game when one player owns ≥80% of 48 nodes. No scoring toward 100, no standoff draw, no resignation, no board-exhaustion handling.
6. **Stalemate is a counter, not a doctrine.** `_triggerStalemateForfeit` (lines 1457–1471) hard-codes the winner to `PLAYER_1` and forces `moveCount = max(moveCount, 35693)`. There is no parity-preserving play; the "standoff" is a timer that fires after enough parries.
7. **Franchise IP is embedded directly.** Player names "Lt. Cmdr. Data" / "Sirna Kolrami" (lines 496, 503), canonical episode dialogue (lines 2996–3028), LCARS palette and pill styling (lines 10–22, 359), and the stardate "42923.4" (line 361) are baked into the distributable. None of it is theme-separated.

## 7. What is worth preserving

Per the master prompt, the prototype is a **reference, not an architecture**. Ideas worth carrying into the native implementation:

- **Two-handed chorded input** (QWER rows / ASDF columns / JKL plateaus / UIOP conduits / Space burst / `;` sever / Enter seal) — a genuinely distinctive rapid-cadence mechanic.
- **Layered holographic space** — three separated plateaus with vertical conduits, readable at a glance.
- **Flux as a spendable resource** that gates action frequency (the *idea*; the implementation is broken).
- **Cycles/enclosures, severing, conduits, dominance, and a parity/stalemate gauge** as named strategic concepts.
- **Procedural oscillator audio** mapped to semantic events (pulse, sever, layer shift, stalemate) — cheap, original, fatigue-resistant.
- **The three named play fantasies**: VS Grandmaster, Standoff, and Local Duel — preserved as modes, not as the broken implementations here.
- **The composure/tilt gauge** as a *presentation* of psychological pressure (driven by explainable match events in the native version, not by a semicolon key).

## 8. Audit verdict

The prototype is a **visual/tonal moodboard with a non-functional game loop**. Its engine is internally inconsistent (two incompatible engines, orchestrator calls that don't match the shipped class), its AI is random, its PvP is a label, its conduits and sever lack strategic depth, its flux economy has no live regen loop, and it embeds unlicensed franchise IP. It must be reimplemented from scratch in a testable native architecture; none of its JavaScript is portable into the macOS app.
