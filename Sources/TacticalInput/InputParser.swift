import Foundation
import TacticalCore

/// Two-handed chorded keyboard input parser. Testable independently from the
/// simulation — feeds on key events, emits Commands.
///
/// Default layout (Triad board, 4×4 × 3 plateaus):
///   Left hand (row/column):
///     Q W E R  →  row 0 1 2 3
///     A S D F  →  column 0 1 2 3
///   Right hand (plateau/action):
///     J K L    →  plateau 0 1 2
///     Space    →  Pulse (at current row/column/plateau)
///     Return   →  Select (move cursor to row/column/plateau)
///     U        →  Forge (edge from cursor to row/column/plateau neighbor)
///     I        →  Traverse conduit (at row/column/plateau)
///     O        →  Seal cycle (at current face candidate)
///     P        →  Reinforce anchor (at row/column/plateau)
///     ;        →  Sever (edge at cursor)
///     H        →  Counter (last enemy action)
///     Y        →  Feint (at row/column/plateau)
///     Backspace → Yield
///     Esc      →  Resign (with confirmation in UI)
///     R        →  Camera reset (handled by renderer, not parsed here)
public struct InputMapping: Sendable, Hashable {
    public let rowKeys: [Character]       // Q W E R
    public let columnKeys: [Character]    // A S D F
    public let plateauKeys: [Character]   // J K L
    public let pulseKey: Character        // Space
    public let selectKey: Character       // Return
    public let forgeKey: Character        // U
    public let traverseKey: Character     // I
    public let sealKey: Character         // O
    public let reinforceKey: Character    // P
    public let severKey: Character        // ;
    public let counterKey: Character      // H
    public let feintKey: Character        // Y
    public let yieldKey: Character        // Backspace
    public let resignKey: Character       // Escape

    public init(
        rowKeys: [Character] = ["q", "w", "e", "r"],
        columnKeys: [Character] = ["a", "s", "d", "f"],
        plateauKeys: [Character] = ["j", "k", "l"],
        pulseKey: Character = " ",
        selectKey: Character = "\r",
        forgeKey: Character = "u",
        traverseKey: Character = "i",
        sealKey: Character = "o",
        reinforceKey: Character = "p",
        severKey: Character = ";",
        counterKey: Character = "h",
        feintKey: Character = "y",
        yieldKey: Character = "\u{8}",   // backspace
        resignKey: Character = "\u{1b}"  // escape
    ) {
        self.rowKeys = rowKeys
        self.columnKeys = columnKeys
        self.plateauKeys = plateauKeys
        self.pulseKey = pulseKey
        self.selectKey = selectKey
        self.forgeKey = forgeKey
        self.traverseKey = traverseKey
        self.sealKey = sealKey
        self.reinforceKey = reinforceKey
        self.severKey = severKey
        self.counterKey = counterKey
        self.feintKey = feintKey
        self.yieldKey = yieldKey
        self.resignKey = resignKey
    }

    public static let `default` = InputMapping()

    public func row(for key: Character) -> Int? {
        rowKeys.firstIndex(of: key.lowercased().first ?? key)
    }
    public func column(for key: Character) -> Int? {
        columnKeys.firstIndex(of: key.lowercased().first ?? key)
    }
    public func plateau(for key: Character) -> Int? {
        plateauKeys.firstIndex(of: key.lowercased().first ?? key)
    }
}

/// The input parser state machine. Tracks held row/column/plateau keys and
/// emits Commands when action keys are pressed.
public final class InputParser {
    public let mapping: InputMapping
    public let player: Player
    public let board: BoardDefinition

    private var heldRow: Int? = nil
    private var heldColumn: Int? = nil
    private var heldPlateau: Int? = nil
    private var cursorNodeId: String = ""

    public init(mapping: InputMapping = .default, player: Player, board: BoardDefinition) {
        self.mapping = mapping
        self.player = player
        self.board = board
        // Initialize cursor from player's first anchor.
        let anchors = player == .player1 ? board.anchors.player1 : board.anchors.player2
        cursorNodeId = anchors.first ?? board.nodes.first!.id
    }

    public var cursorNodeIdValue: String { cursorNodeId }

    /// Synchronize the parser cursor with an external selection (mouse click,
    /// replay scrub, training reset). Without this the parser keeps a stale
    /// cursor and a subsequent keyboard forge/sever targets the wrong node.
    public func setCursorNodeId(_ nodeId: String) {
        guard board.nodeMap[nodeId] != nil else { return }
        cursorNodeId = nodeId
    }

    /// Currently held row index (0-3), or nil if no row key is held.
    public var heldRowValue: Int? { heldRow }
    /// Currently held column index (0-3), or nil if no column key is held.
    public var heldColumnValue: Int? { heldColumn }
    /// Currently held plateau index (0-2), or nil if no plateau key is held.
    public var heldPlateauValue: Int? { heldPlateau }

    /// Current held coordinate (row, column, plateau) if all three are held.
    public var heldCoordinate: (Int, Int, Int)? {
        guard let r = heldRow, let c = heldColumn, let p = heldPlateau else { return nil }
        return (r, c, p)
    }

    /// Node ID for a given (row, column, plateau) on the board.
    /// Convention: row = y, column = x, plateau = p.
    public func nodeId(row: Int, col: Int, plateau: Int) -> String? {
        // Find a node at the given plateau with x=col, y=row.
        let id = "p\(plateau)x\(col)y\(row)"
        return board.nodeMap[id] != nil ? id : nil
    }

    /// Process a key-down event. Returns a Command if the key completes a chord,
    /// or nil if it's a modifier/coordinate key that just updates held state.
    ///
    /// Arrow-key steering and Return selection are NOT handled here — they are
    /// UI-only navigation (see `navigateCursor`/`selectCursor`) and must not
    /// emit a game command or spend a turn. Escape is handled by the app shell
    /// as pause/resume, not resign.
    public func keyDown(_ key: Character) -> Command? {
        let lower = key.lowercased().first ?? key

        // Coordinate keys (held, not action)
        if let r = mapping.row(for: lower) { heldRow = r; return nil }
        if let c = mapping.column(for: lower) { heldColumn = c; return nil }
        if let p = mapping.plateau(for: lower) { heldPlateau = p; return nil }

        // Action keys
        if lower == mapping.pulseKey { return pulseCommand() }
        if lower == mapping.forgeKey { return forgeCommand() }
        if lower == mapping.traverseKey { return traverseCommand() }
        if lower == mapping.sealKey { return sealCommand() }
        if lower == mapping.reinforceKey { return reinforceCommand() }
        if lower == mapping.severKey { return severCommand() }
        if lower == mapping.counterKey { return counterCommand() }
        if lower == mapping.feintKey { return feintCommand() }
        // Yield accepts both macOS Delete (0x7f) and Backspace (0x08).
        if key == mapping.yieldKey || key == Character(UnicodeScalar(0x7f)!) {
            return .yield_(player)
        }

        return nil
    }

    /// Returns true if `key` is a recognized coordinate, action, or yield key.
    /// Used by the app shell to decide whether an unrecognized key should be
    /// swallowed (true) or propagated to the responder chain (false).
    public func recognizes(_ key: Character) -> Bool {
        let lower = key.lowercased().first ?? key
        if mapping.row(for: lower) != nil { return true }
        if mapping.column(for: lower) != nil { return true }
        if mapping.plateau(for: lower) != nil { return true }
        if lower == mapping.pulseKey { return true }
        if lower == mapping.forgeKey { return true }
        if lower == mapping.traverseKey { return true }
        if lower == mapping.sealKey { return true }
        if lower == mapping.reinforceKey { return true }
        if lower == mapping.severKey { return true }
        if lower == mapping.counterKey { return true }
        if lower == mapping.feintKey { return true }
        if key == mapping.yieldKey || key == Character(UnicodeScalar(0x7f)!) { return true }
        return false
    }

    /// UI-only arrow navigation. Moves the cursor to the adjacent node one grid
    /// step in the given direction (same plateau preferred, falling back to the
    /// nearest plateau with a node) and returns the new node ID, or nil if no
    /// node exists. Does NOT emit a game command — visual navigation must not
    /// spend a turn, hand off, or mutate the engine snapshot.
    public func navigateCursor(dx: Int, dy: Int) -> String? {
        guard let current = board.nodeMap[cursorNodeId] else { return nil }
        let targetX = current.x + dx
        let targetY = current.y + dy
        let plateaus = board.plateaus.map(\.index).sorted()
        let ordered = plateaus.firstIndex(of: current.plateau).map { idx in
            Array(plateaus[idx...]) + Array(plateaus[..<idx])
        } ?? plateaus
        for p in ordered {
            if let id = nodeId(row: targetY, col: targetX, plateau: p) {
                cursorNodeId = id
                return id
            }
        }
        return nil
    }

    /// UI-only cursor selection (Return). Moves the cursor to the currently
    /// held coordinate (or stays at the existing cursor if no coordinate is
    /// held) and returns the target node ID. Does NOT emit a game command.
    public func selectCursor() -> String? {
        guard let id = targetNodeId() else { return nil }
        cursorNodeId = id
        return id
    }

    /// Process a key-up event. Clears held coordinate state.
    public func keyUp(_ key: Character) {
        let lower = key.lowercased().first ?? key
        if let r = mapping.row(for: lower), heldRow == r { heldRow = nil }
        if let c = mapping.column(for: lower), heldColumn == c { heldColumn = nil }
        if let p = mapping.plateau(for: lower), heldPlateau == p { heldPlateau = nil }
    }

    /// Clear all held state (e.g. on window focus loss).
    public func reset() {
        heldRow = nil
        heldColumn = nil
        heldPlateau = nil
    }

    // MARK: - Action command builders

    private func targetNodeId() -> String? {
        guard let (row, col, plat) = heldCoordinate else {
            return cursorNodeId
        }
        return nodeId(row: row, col: col, plateau: plat)
    }

    private func pulseCommand() -> Command? {
        guard let id = targetNodeId() else { return nil }
        cursorNodeId = id
        return .pulse(player, id)
    }

    private func forgeCommand() -> Command? {
        // Forge an edge from cursor to the held coordinate node (if adjacent).
        guard let target = targetNodeId(), target != cursorNodeId else { return nil }
        let edgeId = Legality.canonicalEdgeId(cursorNodeId + "--" + target)
        return .forge(player, edgeId)
    }

    private func traverseCommand() -> Command? {
        guard let target = targetNodeId() else { return nil }
        // Traverse the conduit between cursor and target (if one exists).
        let edgeId = Legality.canonicalEdgeId(cursorNodeId + "--" + target)
        return .traverse(player, edgeId)
    }

    private func sealCommand() -> Command? {
        // Seal the face at the current cursor position.
        // Find the face whose boundary contains edges incident to the cursor.
        let cursor = cursorNodeId
        let incidentEdges = board.incidence[cursor] ?? []
        for face in board.faces {
            let shared = face.boundary.filter { incidentEdges.contains($0) }.count
            if shared >= 2 {
                return .seal(player, face.id)
            }
        }
        return nil
    }

    private func reinforceCommand() -> Command? {
        guard let id = targetNodeId() else { return nil }
        return .reinforce(player, id)
    }

    private func severCommand() -> Command? {
        // Sever the edge from cursor to held coordinate (if it exists).
        guard let target = targetNodeId(), target != cursorNodeId else { return nil }
        let edgeId = Legality.canonicalEdgeId(cursorNodeId + "--" + target)
        return .sever(player, edgeId)
    }

    private func counterCommand() -> Command? {
        // Counter requires an event sequence from the previous tick. The UI
        // resolves that against the visible, matching enemy action immediately
        // before submission; a parser should never manufacture a fake seq.
        guard let target = targetNodeId() else { return nil }
        let edgeId = Legality.canonicalEdgeId(cursorNodeId + "--" + target)
        return Command(player: player, action: .counter, targetEdgeId: edgeId)
    }

    private func feintCommand() -> Command? {
        guard let id = targetNodeId() else { return nil }
        return .feint(player, id)
    }
}

/// Resolves a parsed counter intent to the newest compatible, counterable
/// enemy action. Keeping this outside the UI makes counter selection testable
/// and avoids the old `-1` placeholder that guaranteed rejection.
public enum CounterTargetResolver {
    public static func resolve(_ command: Command,
                               counterableActions: [GameState.CounterableAction]) -> Command {
        let normalized = Legality.normalize(command)
        guard normalized.action == .counter,
              normalized.counteredSeq == nil,
              let edgeId = normalized.targetEdgeId else {
            return normalized
        }

        guard let match = counterableActions
            .filter({ $0.player == normalized.player.opponent && $0.targetEdge == edgeId })
            .max(by: { $0.seq < $1.seq }) else {
            return normalized
        }

        return Command(
            player: normalized.player,
            action: normalized.action,
            targetNodeId: normalized.targetNodeId,
            targetEdgeId: normalized.targetEdgeId,
            candidateCycleId: normalized.candidateCycleId,
            counteredSeq: match.seq,
            targetTick: normalized.targetTick
        )
    }
}
