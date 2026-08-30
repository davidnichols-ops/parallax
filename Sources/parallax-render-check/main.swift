import AppKit
import TacticalCore
import TacticalRenderer

/// Headless, real SceneKit rendering for visual review and black-frame checks.
/// This does not simulate a user interaction or claim a live UI play-test.
@main
struct RenderCheck {
    @MainActor
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 2 else {
            print("Usage: parallax-render-check <triad|grandmaster> <output.png> [width] [height]")
            return
        }
        _ = NSApplication.shared
        let board = args[0] == "grandmaster" ? BoardFactory.grandmaster() : BoardFactory.triad()
        let width = args.count > 2 ? Int(args[2]) ?? 1200 : 1200
        let height = args.count > 3 ? Int(args[3]) ?? 680 : 680
        guard width >= 200, width <= 4096, height >= 150, height <= 4096 else {
            throw RenderError.invalidDimensions
        }
        let view = BoardHostingView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        view.reduceMotion = true
        view.configure(board: board, state: GameState(board: board, matchSeed: 1),
                       selectedNodeId: board.anchors.player1.first)
        view.layoutSubtreeIfNeeded()
        guard let image = view.renderSnapshot(), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.noBitmap
        }
        let destination = URL(fileURLWithPath: args[1])
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: destination, options: .atomic)

        var bright = 0, colorful = 0, samples = 0
        var xMin = bitmap.pixelsWide, xMax = 0, yMin = bitmap.pixelsHigh, yMax = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 4) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                samples += 1
                let hi = max(color.redComponent, color.greenComponent, color.blueComponent)
                let lo = min(color.redComponent, color.greenComponent, color.blueComponent)
                if hi > 0.2 {
                    bright += 1
                    xMin = min(xMin, x); xMax = max(xMax, x)
                    yMin = min(yMin, y); yMax = max(yMax, y)
                    if hi - lo > 0.12 { colorful += 1 }
                }
            }
        }
        let report: [String: Any] = [
            "board": board.id, "file": destination.path,
            "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh,
            "sampleCount": samples, "brightSamples": bright, "colorfulSamples": colorful,
            "contentBounds": [xMin, yMin, xMax, yMax],
            "nonBlank": bright > max(20, samples / 100) && colorful > 20
        ]
        let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: json, as: UTF8.self))
        guard bright > max(20, samples / 100), colorful > 20 else { throw RenderError.blankFrame }
    }

    enum RenderError: Error { case invalidDimensions, noBitmap, blankFrame }
}
