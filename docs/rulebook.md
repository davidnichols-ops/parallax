# Parallax — Formal Rulebook

**Status:** Authoritative. The `TacticalCore` engine implements exactly this document. Where code and this document disagree, this document is correct and the code is a bug.

## 0. Canon boundary (required disclaimer)

The television episode *Peak Performance* depicts a public, two-player strategy game played at a luminous table with fast move counters, plateaus, and very long matches. **The episode never defines the board dimensions, pieces, legal moves, plateau topology, scoring system, or win condition.** Every specific rule below is an **original, canon-compatible extrapolation** by the Parallax authors. No claim is made that these are the on-screen rules. Franchise names, characters, and dialogue appear only in an optional, separately-sourced, non-distributed theme pack (see `licensing-and-attribution.md`); the neutral ruleset uses neutral identifiers throughout.

## 1. Definitions and notation

- The game is a **deterministic, turn-resolved, simultaneous-intent strategy game** for two players, played on a fixed graph.
- `P ∈ {P1, P2}` denotes a player; `P̄` denotes the opponent.
- `ℕ` = non-negative integers. All game quantities are integers or fixed-point rationals with denominator 100 (stored as integer hundredths). **No floating point is used in rules logic.**
- The **simulation** advances in integer **ticks** `t ∈ ℕ`, starting at `t = 0`. A tick is the atomic unit of authoritative time. Wall-clock time is never read by the rules.
- A **command** `c = (player, action, args, targetTick)` is an immutable input. Commands are processed in a canonical order (§6).
- An **event** `e = (type, payload, tick, seq)` is an immutable, append-only record of a state change.
- A **snapshot** `S_t` is the complete serializable state at the end of tick `t`.
- The **state hash** `H(S_t) = SHA-256(canonical_encode(S_t))` is computed over a canonical byte encoding (sorted keys, fixed-width integers). It must match across client, server, replay, arm64, and x86_64.

## 2. The board

A **board definition** `B = (V, E, F, P, anchors, conduits)` is versioned data.

### 2.1 Nodes
`V` is a finite set of **nodes**. Each node `v` has:
- `id`: a stable string unique in `B`.
- `plateau`: an integer plateau index `∈ [0, nPlateaus)`.
- `x, y`: integer coordinates within its plateau (not used for rules except topology authoring; rules never infer logic from rendered coordinates).
- `kind ∈ {Anchor, Standard, Conduit}`.
- `owner ∈ {Neutral, P1, P2}`.
- `influence ∈ [0, 100]` (integer).
- `locked ∈ {true, false}` — a locked node cannot change owner.

### 2.2 Edges
`E` is a finite set of **edges**. Each edge `e` has:
- `id`: stable string.
- `endpoints`: unordered pair `{u, v}` with `u, v ∈ V`.
- `kind ∈ {Intra, Conduit}`.
- `owner ∈ {Neutral, P1, P2, Severed}`.
- `flux ∈ [0, 100]` (integer) — edge integrity.
- `capacity ∈ ℕ` — for conduits, the maximum traversal pressure (Intra edges have capacity 1).
- `severed ∈ {true, false}`, `cooldown ∈ ℕ` (ticks remaining until repair).
- `sealed ∈ {true, false}` — true if part of a sealed cycle.

### 2.3 Faces and sectors (authored territory)
`F` is a finite set of **faces**. Each face `f` has:
- `id`: stable string.
- `boundary`: an ordered list of edge ids forming a simple cycle in `E`.
- `plateau`: the plateau the face lies on, or `Cross` for a cross-plateau sector.
- `area ∈ ℕ` — an authored weight (strategic value).

A face is the **only** unit of territory. Connectivity or rendered coordinates alone never produce territory. Faces may **nest** (a face whose boundary lies inside another) but may not partially overlap. Each face is controlled by at most one player (§8).

### 2.4 Plateaus
`P` is an ordered list of plateau descriptors: `{index, name, nodeIds, faceIds}`. The Triad board has 3 plateaus; the Grandmaster board has 6. The phrase "sixth plateau" is flavor only.

### 2.5 Anchors
`anchors = {P1: [a1, a2], P2: [b1, b2]}`. Anchor nodes begin owned by their player, `influence = 100`, `locked = true`. Anchors are never captured.

### 2.6 Conduits
`conduits` is the subset of edges with `kind = Conduit`. Conduits are authored vertical or cross-plateau edges with `capacity ≥ 1`. A conduit is **occluded** for a player if neither endpoint is owned by that player and the conduit is `Severed` (§7.4).

## 3. Board families

### 3.1 Triad (training, 48 nodes)
- 3 plateaus (Alpha, Beta, Gamma), each a 4×4 grid → 16 nodes/plateau, 48 total.
- Intra edges: the 24 grid-neighbor edges per plateau (horizontal + vertical), 72 total.
- Faces: the 9 unit squares per plateau (3×3 of 2×2 node cells), 27 faces, each `area = 1`.
- Conduits: at the 4 corner coordinates `(0,0),(0,3),(3,0),(3,3)` and 2 center coordinates `(1,1),(2,2)`, an Alpha↔Beta and a Beta↔Gamma conduit (12 conduits). No direct Alpha↔Gamma conduit in the neutral Triad topology (the prototype's "vortex" is dropped as tactically incoherent).
- Anchors: P1 = Alpha(0,0) + Gamma(0,3); P2 = Alpha(3,3) + Gamma(3,0).

### 3.2 Grandmaster (competitive, 6 plateaus)
- 6 visually distinct plateaus with **irregular, data-authored** geometry (not all 4×4; some plateaus have 5- or 6-node faces, missing nodes, and bridging conduits).
- Multiple interlinked fronts; conduits with `capacity ∈ {1,2,3}`; cross-plateau sectors via authored `Cross` faces whose boundaries traverse conduits.
- Topology is validated at load time (§12). The exact layout is defined in versioned data files, not in code.

## 4. Flux economy

Each player has `flux ∈ [0, MAX_FLUX]`, `MAX_FLUX = 10000` (hundredths → displayed 100.00). All costs are in hundredths.

### 4.1 Costs (versioned balance data `BALANCE_v`)
| Action | Cost (hundredths) |
|---|---|
| Select Coordinate | 0 |
| Pulse Node | 500 |
| Forge Link | 400 |
| Traverse Conduit | `1200 / capacity` (min 600) |
| Counter Vector | 700 |
| Sever Link | 1500 |
| Seal Cycle | 1000 |
| Reinforce Anchor | 800 |
| Feint | 300 |
| Yield | 0 |

### 4.2 Regeneration
At the end of each tick, for each player `P`:
```
regen(P) = BASE_REGEN
        + STABLE_NODE_RATE * |{v ∈ V : owner(v)=P ∧ stable(v)}|
        + CYCLE_RATE * |sealedCycles(P)|
        + SECTOR_RATE * Σ area(f) for f controlled by P
flux(P) := min(MAX_FLUX, flux(P) + regen(P))
```
with `BASE_REGEN = 40`, `STABLE_NODE_RATE = 8`, `CYCLE_RATE = 25`, `SECTOR_RATE = 6` (all hundredths/tick). A node is **stable** if it is owned, has `influence ≥ 60`, and all its owned incident edges are not severed.

### 4.3 Tactical debt and soft-lock prevention
- If `flux(P) < cost(action)`, the action is **rejected** (event `ActionRejected`, reason `InsufficientFlux`).
- A player with `flux < 300` may always issue **Select Coordinate**, **Yield**, or **Feint** (cost ≤ 300). These three actions are the **soft-lock floor**: they always change at least the cursor/intent state, so a player is never without a legal move.
- Overspending is impossible (costs are checked before application). There is no negative flux.

### 4.4 Hoarding cap
`MAX_FLUX` is the hard cap. There is no separate hoarding penalty; the cap itself bounds savings. Projected costs are exposed by the engine via `projectedCost(state, command)` before commitment (§9).

## 5. Actions (vocabulary)

Each action has: cost, range/targeting, wind-up, counter window, success/rejection event, undo policy, replay encoding, accessibility label. Wind-up and counter windows are measured in **ticks**. Undo is allowed only in local untimed modes and only for the most recent unresolved command (replays record the undo as an event).

### 5.1 Select Coordinate
- Cost 0. Sets the player's **cursor** `(plateau, x, y)` and pending target. No state change to the graph. Event `CursorMoved`.
- This is the soft-lock-floor selector.

### 5.2 Pulse Node
- Cost 500. Target: a node `v` adjacent (via an Intra edge) to a node owned by `P` with `influence ≥ 40`, OR any node `v` adjacent to the player's cursor node via an Intra edge not severed.
- Effect: increases `influence(v)` by `PULSE_GAIN = 35`; if `influence(v) ≥ 100` or `owner(v) = Neutral`, sets `owner(v) = P`, `influence(v) = 100`. If `owner(v) = P̄` and `influence(v) < 100`, the pulse **contests** (reduces `influence(v)` by `PULSE_GAIN` instead; if it reaches 0, `owner(v)` becomes Neutral — it does **not** flip directly to `P`). Defender priority: an owned non-anchor node is never captured in a single pulse; it must first be neutralized.
- Wind-up 0. Counter window 1 tick (a Counter Vector in the same or next tick may negate, §5.5).
- Event `NodePulsed` or `NodeContested`.

### 5.3 Forge Link
- Cost 400. Target: an Intra edge `e = {u,v}` where `owner(u) = P` and `owner(v) ∈ {P, Neutral}` and `e` is not `Severed`.
- Effect: `owner(e) = P`, `flux(e) = min(100, flux(e) + 50)`. If both endpoints owned by `P`, the edge becomes **reinforced** (`flux(e) = 100`).
- Event `LinkForged`.

### 5.4 Traverse Conduit
- Cost `1200 / capacity` (min 600). Target: a Conduit edge `e = {u, v}` where `owner(u) = P` and `e` is not `Severed` and not occluded for `P`.
- Effect: `owner(e) = P`, `flux(e) = 100`; the target node `v` gets `influence(v) += 50`; if `owner(v) = Neutral`, `owner(v) = P`. Moves the player's cursor to `v`.
- Capacity pressure: if `P̄` has traversed the same conduit in the previous `capacity` ticks, the conduit is **contested** and the traversal instead reduces `flux(e)` by 50 (a counter-pressure effect) without capturing `v`.
- Event `ConduitTraversed` or `ConduitContested`.

### 5.5 Counter Vector
- Cost 700. Target: an enemy edge `e` owned by `P̄` incident to a node owned by `P`, **within the counter window** of the action being countered (the countered action's `seq` is recorded).
- Effect: `flux(e) -= 60`. If `flux(e) ≤ 0`, `owner(e) = Neutral`, `flux(e) = 0` (the edge is **disputed**, not severed). Counts as a **parry** for composure (§11).
- Counter window: 1 tick after the countered action's tick.
- Event `VectorCountered` or `CounterFailed` (if the target edge is no longer enemy-owned).

### 5.6 Sever Link
- Cost 1500. Target: an enemy or disputed edge `e` (Intra or Conduit) where `owner(e) = P̄` or `owner(e) = Severed`-disputed.
- Effect: `owner(e) = Severed`, `severed(e) = true`, `cooldown(e) = SEVER_COOLDOWN = 45` ticks, `flux(e) = 0`. Propagation: any face whose boundary includes `e` loses its controlled status for `P̄` immediately (re-evaluated at §8). Any sealed cycle using `e` is **broken** (un-sealed, §7).
- A **Shield** counter (a Reinforce Anchor on an endpoint, §5.8, issued in the same tick) reduces `cooldown` to 15 and prevents cycle breakage.
- Event `LinkSevered`.

### 5.7 Seal Cycle
- Cost 1000. Target: a **candidate cycle** — a simple cycle in the subgraph of edges owned by `P` and not severed, whose enclosed face(s) are not already sealed.
- The engine **shows the candidate cycle** (returns it in the command's pre-check result) before sealing. The player commits by issuing the action.
- Effect: marks the cycle's edges `sealed = true`; awards control of the enclosed face(s) to `P` (§8); adds `CYCLE_BONUS = 10` to score.
- Nested cycles: an inner face already sealed by `P̄` blocks sealing the outer face. An inner face sealed by `P` allows the outer to seal (the inner remains separately scored).
- Event `CycleSealed` with `cycleEdges` and `faces`.

### 5.8 Reinforce Anchor
- Cost 800. Target: an anchor node `a` owned by `P`, or a node `v` owned by `P` with `influence = 100`.
- Effect: sets `influence(v) = 100`, and for the next `SHIELD_WINDOW = 3` ticks any sever targeting an edge incident to `v` is **shielded** (reduced cooldown, no cycle breakage — §5.6). On an anchor, additionally regenerates `+200` flux immediately (anchors are supply sources).
- Event `AnchorReinforced`.

### 5.9 Feint
- Cost 300. Target: a node `v` adjacent to the cursor.
- Effect: no graph state change, but records a **feint marker** that, if `P̄` issues a Counter Vector against `v` in the next 2 ticks, costs `P̄` an extra `200` flux and grants `P` a `+1` initiative token (§10). Feints are the soft-lock-floor pressure tool.
- Event `FeintRegistered` (visible to `P` only; `P̄` sees only `OpponentFeinted` without location).

### 5.10 Yield
- Cost 0. The player passes the tick with no graph change. Counts as a **non-parry** for composure (§11): repeated yields lower the yielding player's composure. A yield is always legal (soft-lock floor).

## 6. Tick resolution and canonical ordering

### 6.1 Command queue
Each tick `t`, the authority collects all commands `c` with `c.targetTick = t`. Commands are **immutable**. The authority assigns each a monotonic `seq`.

### 6.2 Canonical order
Commands are processed in this order (deterministic, no random tie-break unless §6.3 applies):
1. **Yield** commands (P1 then P2).
2. **Select Coordinate** (P1 then P2) — cursor updates only.
3. **Reinforce Anchor** (P1 then P2) — establishes shields before sever resolution.
4. **Sever Link** (P1 then P2) — applies shields from step 3.
5. **Counter Vector** (P1 then P2) — resolves against actions from the *previous* tick's recorded seqs.
6. **Forge Link**, **Traverse Conduit** (P1 then P2).
7. **Pulse Node** (P1 then P2).
8. **Seal Cycle** (P1 then P2) — re-evaluates territory after all edge/node changes.
9. **Feint** (P1 then P2) — registers markers for next tick.

"P1 then P2" is a fixed canonical order; it does **not** confer an advantage because simultaneous intent is resolved by the conflict matrix (§6.3) and initiative (§10) breaks true ties.

### 6.3 Conflict matrix
When two commands in the same tick target the **same edge or node** on opposite sides:

| P1 action \ P2 action | Pulse | Forge | Traverse | Counter | Sever | Seal | Reinforce |
|---|---|---|---|---|---|---|---|
| Pulse | both contest (influence cancels) | P2 Forge holds; P1 Pulse contests node only | P2 Traverse wins (capacity pressure) | P2 Counter negates P1 Pulse | P2 Sever disrupts P1 source edge | P2 Seal claims edge; P1 Pulse rejected | P1 Pulse proceeds; P2 Reinforce shields |
| Forge | P1 Forge holds | both hold (shared edge → disputed) | P1 Forge blocks P2 Traverse | P2 Counter reduces P1 edge flux | P2 Sever wins | higher-initiative Seal claims | both proceed |
| Traverse | P1 Traverse wins | P1 Forge blocks | capacity-pressure contest (§5.4) | P2 Counter negates | P2 Sever wins | P1 Traverse rejected (Seal first) | both proceed |
| Counter | P1 Counter negates | P1 Counter reduces | P1 Counter negates | both parry (mutual composure +) | P1 Counter reduces Sever cooldown | P1 Counter rejected | P1 Counter rejected |
| Sever | P1 Sever wins | P1 Sever wins | P1 Sever wins | P2 Counter reduces | mutual sever (both edges Severed) | P1 Sever breaks P2 Seal | P2 Reinforce shields (Sever reduced) |
| Seal | P1 Seal claims | P1 Seal claims | P2 Traverse rejected | P2 Counter rejected | P2 Sever breaks P1 Seal | higher-initiative Seal wins | both proceed |
| Reinforce | both proceed | both proceed | both proceed | both proceed | shield applies | both proceed | both proceed |

**Initiative tie-break** (§10): when the matrix says "higher-initiative wins" and initiative is equal, the **canonical P1-then-P2 order** decides. This is the **only** place canonical order decides a contest; it is documented and symmetric over a match because initiative alternates (§10.3).

### 6.4 Random tie-break (rare, seeded)
If a rule requires a random choice (e.g., two equally-scored bot moves with no deterministic ordering), the engine draws from a **seeded PRNG** (`SplitMix64` seeded by `(matchSeed, tick, seq)`). The draw is recorded in the event stream so replays reproduce it. **Rules logic itself never requires randomness**; only bot selection does, and only as a last resort.

## 7. Cycles, territory, and severing

### 7.1 Cycle detection
A **cycle** is a simple cycle in the subgraph `G_P = (V_P, E_P)` where `E_P = {e ∈ E : owner(e)=P ∧ !severed(e)}`. Cycle detection runs over the authored face boundaries: a face `f` is **sealable** by `P` iff every edge in `f.boundary` is in `E_P` and `f` is not already sealed by `P̄`. This bounds cycle detection to authored faces (no arbitrary graph roaming), making it `O(|F|)` and deterministic.

### 7.2 Territory
A face `f` is **controlled by P** iff:
1. Every edge in `f.boundary` has `owner = P` and `!severed`, OR
2. `f` is sealed by `P` (§5.7).

Territory(f) = controlled area. **Double counting is prevented** by the nesting rule (§5.7): an outer face is only scored if no inner face of the same player is already scored separately; if both are sealed, both score (they are distinct faces). The total controlled territory of `P` is the sum over faces controlled by `P`, with each face counted once.

### 7.3 Cross-plateau sectors
A `Cross` face has a boundary that includes Conduit edges. It is controlled by `P` iff all its boundary edges (Intra + Conduit) are owned by `P` and not severed. This is the only way conduits create territory directly.

### 7.4 Sever consequences
A sever sets the edge to `Severed` for `cooldown` ticks. Consequences, evaluated immediately and at each tick:
- Any face using that edge loses `controlled` status for its previous owner.
- Any sealed cycle using that edge is **broken**: its edges lose `sealed = true`, and its faces lose `controlled` (re-scored at §8).
- Connectivity for influence propagation is cut along that edge (a node beyond the sever cannot receive influence through it).
- At `cooldown = 0`, the edge becomes `Neutral`, `severed = false`, `flux = 0` (it must be re-forged).

## 8. Scoring

Each player's **score** is an integer in `[0, ∞)`, displayed toward the **match pressure target of 100**. Score is recomputed at the end of each tick:

```
score(P) = TERRITORY_RATE * Σ area(f) for f controlled by P
         + CYCLE_RATE_SCORE * |sealedCycles(P)|
         + COUNTER_RATE * |successfulCounters(P)|
         + OBJECTIVE_BONUS(P)
```
with `TERRITORY_RATE = 4`, `CYCLE_RATE_SCORE = 5`, `COUNTER_RATE = 2`. `OBJECTIVE_BONUS` is a mode-specific authored bonus (e.g., controlling a designated central face). Score is **not** reset by losing territory; it is a cumulative pressure metric. The **match-pressure display** is `min(100, score(P))`; the raw score is also shown.

## 9. Legality and pre-commitment projection

`isLegal(state, command) → Bool` and `projectedCost(state, command) → Int` are pure functions exposed by the engine. A command is **legal** iff:
- The player's cursor/selection satisfies the action's targeting rule.
- `flux(player) ≥ cost(action)`.
- The target edge/node exists and is in the required ownership state.
- The action's counter window is respected (for Counter Vector).

Illegal commands produce `ActionRejected` with a typed reason and **do not change state**. The UI is expected to call `isLegal`/`projectedCost` for hover previews; the authority re-checks on submission.

## 10. Initiative and parity

### 10.1 Initiative tokens
Each player has `initiative ∈ ℕ`. `+1` for: a successful Counter, a Feint that drew a counter, winning a Seal tie. `-1` for: a Yield, a rejected action. Initiative is used only to break matrix ties (§6.3).

### 10.2 Parity
`parity = score(P1) - score(P2)`. A position is **in parity** iff `|parity| ≤ PARITY_BAND = 4` and neither player controls a winning-line face (a face whose control would push score ≥ 100).

### 10.3 Initiative alternation
To keep the canonical P1-then-P2 order fair over a match, **initiative flips** at the start of each tick: the player who acted second in tick `t` acts first in tick `t+1`'s canonical order. This is recorded in the snapshot. The conflict matrix's "canonical order" tie-break therefore favors each player ~50% of ticks over a long match.

## 11. Composure, standoff, and endings

### 11.1 Composure gauge
Each player has `composure ∈ [0, 100]` (integer, displayed as a tilt gauge). Composure changes by **explainable match events only**, never by a key press or a wall-clock timer:
- `+3` for a successful Counter (parry).
- `+2` for maintaining parity across a tick (in-parity at tick end).
- `-4` for a rejected action (miscommand).
- `-6` for losing a sealed cycle to a sever.
- `-8` for a Yield while the opponent did not yield.
- `-10` for falling out of parity by more than `PARITY_BAND`.

Composure never affects legal moves or scores; it is **presentation** (HUD, audio, bot personality). It is, however, recorded in events and reproducible.

### 11.2 Victory
A player **wins decisively** when their `score ≥ 100` and `parity > PARITY_BAND` at the end of a tick. The match ends immediately (event `MatchWon`, `winner = P`, `reason = DecisiveScore`).

### 11.3 Resignation
A player may issue `Resign` (a meta-command, not a tick action). Event `MatchWon`, `winner = P̄`, `reason = Resignation`.

### 11.4 Board exhaustion
If, for `EXHAUSTION_TICKS = 40` consecutive ticks, **no** command from either player changes any edge ownership, node ownership, or sealed cycle, the match ends: `MatchDrawn`, `reason = BoardExhaustion`. (This is the rules-valid replacement for "no legal moves" — because the soft-lock floor always permits Select/Yield/Feint, exhaustion is defined by *no meaningful change*, not by no legal move.)

### 11.5 Standoff doctrine
Standoff is a **first-class play intention**, not a mode. A player executes the standoff doctrine by:
- Maintaining parity (§10.2) every tick.
- Issuing Counters against every destabilizing attack (each counter is a valid, score-relevant action — it reduces enemy edge flux and can dispute edges).
- Denying the opponent a clean score by severing or disputing winning-line edges.
- Using Feints to drain the opponent's flux via counter costs.

This sustains **arbitrarily long** matches (tens of thousands of ticks) through **valid, score-relevant actions**, not an infinite no-op loop. The composure gauge visualizes the psychological strain; a player whose composure hits 0 has **not** lost — they may continue — but a bot may resign at composure 0 per its personality (§11.6).

### 11.6 Bot resignation
A bot may issue `Resign` when its composure is 0 **and** its evaluation reports no parity-restoring line within its search budget. This is the rules-valid analog of the episode's frustration forfeit. It is a bot personality decision, never a rules engine outcome.

### 11.7 Disconnects and server interruption
If a client disconnects, the authority **checkpoints** the match (snapshot + event log) and pauses tick advancement. On reconnect within `RECONNECT_TICKS = 600` ticks of game time, the match resumes from the checkpoint. After that, the disconnected player's commands are auto-Yielded until `BoardExhaustion` (§11.4) or a timeout (§12.3).

## 12. Time controls, disconnects, tie-breakers

### 12.1 Time controls (configurable)
- **Untimed analysis**: no clock; ticks advance when both players have submitted (or yielded).
- **Blitz**: each player has `BLITZ_TIME = 300` seconds of wall-clock budget (server-tracked); a player exceeding it loses on time (`MatchWon`, `reason = Timeout`).
- **Tournament**: `TOURNAMENT_TIME = 1800` seconds + `BYOYOMI = 30` seconds per move increment.

Wall-clock is **server-owned** and never affects determinism; the simulation itself is tick-based.

### 12.2 Tie-breakers (tournament only, deterministic, in order)
1. Higher score.
2. More controlled territory (sum of `area`).
3. More sealed cycles.
4. More successful counters.
5. Higher composure at match end.
6. Final: the player with initiative at the last tick wins (recorded, deterministic).

### 12.3 Server interruption
If the authority crashes mid-match, it resumes from the last snapshot + replayed events. If the event log is corrupted, the match is voided (`MatchVoided`) and must be replayed from the initial seed (replays are deterministic, so the same commands reproduce the same match).

## 13. What the rules do not depend on

- **No** wall-clock time in rules logic (only in clocks, server-owned).
- **No** renderer state or rendered coordinates.
- **No** nondeterministic collection order (all iterations are over sorted stable IDs).
- **No** unexplained magic numbers (every constant above is named and lives in versioned `BALANCE_v` data).
- **No** hidden opponent information in legality checks (the engine's `isLegal` uses only public state + the acting player's private cursor; the authority validates commands it receives).

## 14. Worked diagram (Triad, one plateau, 2×2 corner)

```
Nodes:  (0,0)P1-anchor  (1,0)         (2,0)         (3,0)
        (0,1)           (1,1)conduit  (2,1)         (3,1)
        (0,2)           (1,2)         (2,2)conduit  (3,2)
        (0,3)           (1,3)         (2,3)         (3,3)P2-anchor

Faces (unit squares): f00 bounded by edges (0,0)-(1,0),(1,0)-(1,1),(1,1)-(0,1),(0,1)-(0,0).
  P1 seals f00 iff all 4 edges are owned by P1 and not severed.
  Score from f00 = TERRITORY_RATE * area(1) = 4.
  If P2 severs edge (1,0)-(1,1) while f00 is sealed by P1, f00 becomes uncontrolled,
  the sealed cycle breaks, P1 composure -6.
```

## 15. Open items deferred to later slices

- Grandmaster board's exact authored topology (data file, validated by §12 of the master prompt's tooling).
- Bot evaluation features and search budgets (defined in `TacticalBots`, constrained by this rulebook).
- Network protocol schema (defined in `TacticalNetworking`, encoding these commands/events).
- Theme pack contents (franchise-specific, non-distributed, see `licensing-and-attribution.md`).

This rulebook is **frozen** for the `TacticalCore v1` ruleset. Changes require a versioned `BALANCE_v` bump and a ruleset version flag in every command and snapshot.
