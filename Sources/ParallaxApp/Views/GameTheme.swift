import SwiftUI
import TacticalCore

enum GameTheme {
    static let background = Color(red: 0.018, green: 0.027, blue: 0.035)
    static let panel = Color(red: 0.055, green: 0.078, blue: 0.085)
    static let ink = Color(red: 0.91, green: 0.94, blue: 0.89)
    static let muted = Color(red: 0.57, green: 0.66, blue: 0.65)
    static let teal = Color(red: 0.38, green: 0.91, blue: 0.74)
    static let gold = Color(red: 0.88, green: 0.90, blue: 0.49)
    static let red = Color(red: 1, green: 0.32, blue: 0.25)
    static let lavender = Color(red: 0.71, green: 0.65, blue: 0.9)

    static func readable(_ text: String, board: BoardDefinition) -> String {
        var result = text
        for node in board.nodes {
            let column = UnicodeScalar(65 + node.x).map { String(Character($0)) } ?? "\(node.x)"
            result = result.replacingOccurrences(of: node.id, with: "plane \(node.plateau + 1) \(column)\(node.y + 1)")
        }
        return result
    }
}

struct ConsoleButtonStyle: ButtonStyle {
    var accent: Color = GameTheme.ink
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(accent)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(accent.opacity(configuration.isPressed ? 0.17 : 0.05))
            .overlay { RoundedRectangle(cornerRadius: 3).stroke(accent.opacity(configuration.isPressed ? 0.65 : 0.23), lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .opacity(isEnabled ? 1 : 0.38)
    }
}
