import Foundation

/// Cycle and territory evaluation over authored faces (rulebook §7).
/// Detection is O(|F|) and deterministic: a face is sealable by P iff every
/// boundary edge is owned by P and not severed.
public enum Territory {

    /// Is `faceId` sealable by `player` right now?
    public static func isSealable(_ faceId: String, by player: Player,
                                  state: GameState) -> Bool {
        guard let face = state.board.faceMap[faceId] else { return false }
        let owner = player.owner
        for eid in face.boundary {
            guard let e = state.edges[eid] else { return false }
            if e.owner != owner || e.severed { return false }
        }
        // Not already sealed by this player (sealing again is a no-op rejection).
        if state.faces[faceId]?.sealedBy == owner { return false }
        // Inner face sealed by opponent blocks (nesting rule).
        if let inner = innerFaceSealedByOpponent(faceId, opponent: player.opponent, state: state) {
            _ = inner
            return false
        }
        return true
    }

    /// All faces currently controlled by `player` (rulebook §7.2).
    public static func controlledFaces(_ player: Player, state: GameState) -> [String] {
        let owner = player.owner
        var result: [String] = []
        for face in state.board.faces {
            if let fs = state.faces[face.id] {
                if fs.sealedBy == owner { result.append(face.id); continue }
            }
            // Boundary-controlled?
            var allOwned = true
            for eid in face.boundary {
                guard let e = state.edges[eid] else { allOwned = false; break }
                if e.owner != owner || e.severed { allOwned = false; break }
            }
            if allOwned { result.append(face.id) }
        }
        return result
    }

    /// Total controlled area for `player`.
    public static func controlledArea(_ player: Player, state: GameState) -> Int {
        let ids = controlledFaces(player, state: state)
        var total = 0
        for id in ids {
            if let f = state.board.faceMap[id] { total += f.area }
        }
        return total
    }

    /// Faces sealed by `player` (sealed cycles).
    public static func sealedFaces(_ player: Player, state: GameState) -> [String] {
        state.board.faces.compactMap { f in
            state.faces[f.id]?.sealedBy == player.owner ? f.id : nil
        }
    }

    /// Recompute face control from edge ownership (called after edge changes).
    /// Sealed faces retain their controller until their cycle is broken.
    public static func recomputeControl(state: inout GameState) {
        for face in state.board.faces {
            var fs = state.faces[face.id] ?? FaceState()
            // If sealed and cycle still intact, keep control.
            if let by = fs.sealedBy {
                var intact = true
                for eid in face.boundary {
                    if let e = state.edges[eid], e.severed || e.owner != by {
                        intact = false; break
                    }
                }
                if intact {
                    fs.controller = by
                    state.faces[face.id] = fs
                    continue
                } else {
                    // Cycle broken.
                    fs.sealedBy = nil
                    fs.sealedCycleId = nil
                    fs.controller = nil
                    state.faces[face.id] = fs
                }
            }
            // Boundary control.
            var controller: Owner? = nil
            for eid in face.boundary {
                guard let e = state.edges[eid] else { controller = nil; break }
                if e.severed { controller = nil; break }
                if e.owner == .neutral || !e.owner.isPlayer { controller = nil; break }
                if controller == nil { controller = e.owner }
                else if controller != e.owner { controller = nil; break }
            }
            fs.controller = controller
            state.faces[face.id] = fs
        }
    }

    /// Break any sealed cycle that uses `edgeId` (called on sever).
    public static func breakCyclesThrough(_ edgeId: String, state: inout GameState) -> [String] {
        var broken: [String] = []
        for face in state.board.faces {
            if face.boundary.contains(edgeId),
               let by = state.faces[face.id]?.sealedBy {
                var fs = state.faces[face.id]!
                fs.sealedBy = nil
                fs.sealedCycleId = nil
                fs.controller = nil
                state.faces[face.id] = fs
                // Un-seal the boundary edges' membership.
                for eid in face.boundary {
                    if var es = state.edges[eid] {
                        es.sealed = false
                        es.sealedCycleIds.removeAll { $0 == face.id }
                        state.edges[eid] = es
                    }
                }
                // Un-seal the nodes' membership.
                for eid in face.boundary {
                    if let def = state.board.edgeMap[eid] {
                        for nid in [def.u, def.v] {
                            if var ns = state.nodes[nid] {
                                ns.sealedCycleIds.removeAll { $0 == face.id }
                                state.nodes[nid] = ns
                            }
                        }
                    }
                }
                broken.append(face.id)
                _ = by
            }
        }
        return broken
    }

    /// Find an inner face of `faceId` that is sealed by `opponent` (nesting block).
    /// For the Triad/regular grid, an inner face shares ≥2 boundary edges with
    /// the outer and lies on the same plateau. (Full geometric nesting uses
    /// authored containment data in a later slice; this conservative rule blocks
    /// re-sealing an opponent's interior.)
    static func innerFaceSealedByOpponent(_ faceId: String, opponent: Player,
                                          state: GameState) -> String? {
        guard let outer = state.board.faceMap[faceId] else { return nil }
        let outerEdges = Set(outer.boundary)
        for face in state.board.faces {
            if face.id == faceId { continue }
            if face.plateau != outer.plateau { continue }
            if state.faces[face.id]?.sealedBy != opponent.owner { continue }
            let shared = face.boundary.filter { outerEdges.contains($0) }.count
            if shared >= 2 { return face.id }
        }
        return nil
    }
}
