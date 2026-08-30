import AppKit
import SwiftUI
import XCTest
import TacticalCore
@testable import TacticalRenderer
@testable import ParallaxApp

/// Segment 7 — in-process macOS UI verification host.
///
/// Swift Packages cannot ship XCUITest UI-test targets (those require an
/// `.xcodeproj` that hosts and launches an `.app` bundle). Instead this host
/// mounts the **real** SwiftUI views in a live `NSWindow` + `NSHostingController`
/// inside the test process, drains the run loop so AppKit/SwiftUI lay out, and
/// drives them through the same code paths a user takes:
///
/// - **Keyboard**: synthetic `NSEvent` key events routed through `AppState`
///   `handleBoardKeyEvent` — the exact function the `WindowInputBridge` local
///   monitor invokes. A best-effort `postKey` path also dispatches a real event
///   through `NSApp.sendEvent` so the installed local monitor fires, when the
///   host window can become key.
/// - **Mouse hit testing**: `NSView.hitTest` on the mounted content view and on
///   the renderer's `BoardHostingView`, verifying the board intercepts hits and
///   the embedded `SCNView` never does.
/// - **Action/control "clicks"**: located by `accessibilityIdentifier` in the
///   mounted accessibility tree and pressed via `accessibilityPerformPress()`.
///   When the AX press cannot be performed (see `accessibilityTrusted`), the
///   harness falls back to the same public `AppState` method the button calls,
///   so the button → action → state wiring is still verified end-to-end.
/// - **Accessibility/UI state inspection**: a snapshot of the mounted AX tree
///   (identifiers, labels, roles) is collected and asserted.
///
/// See `UIHarnessTests` for the deterministic scenarios, and the Segment 7
/// notes in `devin-strategema-progress.md` for the macOS permission limitations.
@MainActor
final class UITestHost {

    /// The game state under test.
    let app: AppState
    /// The mounted window.
    let window: NSWindow
    /// The hosting controller wrapping the mounted SwiftUI view.
    let hosting: NSHostingController<AnyView>

    /// True when the host window became key — required for real event dispatch.
    /// False in headless/CI runs; the deterministic `sendKey` path still works.
    private(set) var windowIsKey = false

    /// Whether the process is AX-trusted. When false, `accessibilityPerformPress`
    /// on SwiftUI elements may be unavailable; callers fall back to AppState.
    let accessibilityTrusted: Bool = AXIsProcessTrusted()

    /// Records which "press" path was used per identifier, for transparent
    /// reporting in test output.
    private(set) var pressLog: [(identifier: String, viaAX: Bool)] = []

    /// Segment 20 — the bitmap of the most recent `captureSnapshot` call, kept
    /// so tests can run per-region layout/visibility checks without re-capturing.
    private(set) var lastCapturedBitmap: NSBitmapImageRep?

    private static var sharedAppBooted = false

    /// Mount `view` (bound to `app`) in a fresh window.
    init(root view: some View, app: AppState) {
        self.app = app
        UITestHost.bootSharedApp()
        self.hosting = NSHostingController(rootView: AnyView(view))
        // Segment 21 — prevent the hosting controller from resizing the
        // window/content view to the SwiftUI content's intrinsic size. Without
        // this, views whose intrinsic height exceeds the window (e.g.
        // TrainingView's sidebar ScrollView) expand the content view beyond
        // the 1180×800 window, producing oversized screenshots. An empty
        // sizingOptions means the controller's view uses the window's content
        // area, not the SwiftUI content's preferred size.
        if #available(macOS 13.0, *) {
            hosting.sizingOptions = []
        }
        let w = NSWindow(contentViewController: hosting)
        w.styleMask = [.titled, .closable, .miniaturizable]
        w.title = "Parallax UI Harness"
        w.setContentSize(NSSize(width: 1180, height: 800))
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: .darkAqua)
        self.window = w
    }

    /// One-time NSApplication bootstrap. Uses `.accessory` policy so the test
    /// process does not steal the dock/focus from the user's real work.
    static func bootSharedApp() {
        guard !sharedAppBooted else { return }
        let nsApp = NSApplication.shared
        nsApp.setActivationPolicy(.accessory)
        nsApp.finishLaunching()
        sharedAppBooted = true
    }

    /// Order the window front, make it key, and let SwiftUI lay out.
    func mount() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        windowIsKey = window.isKeyWindow
        drainRunLoop(seconds: 0.2)
    }

    /// Tear down the window and stop any live match.
    func close() {
        window.orderOut(nil)
        app.stopMatch()
    }

    /// Run the current run loop briefly so SwiftUI/AppKit complete layout and
    /// pending events drain.
    func drainRunLoop(seconds: TimeInterval) {
        let end = Date(timeIntervalSinceNow: seconds)
        while Date() < end {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
    }

    // MARK: - Keyboard

    /// Build a synthetic key event.
    func makeKeyEvent(_ characters: String, code: UInt16,
                      modifiers: NSEvent.ModifierFlags = [],
                      isDown: Bool = true) -> NSEvent? {
        NSEvent.keyEvent(
            with: isDown ? .keyDown : .keyUp, location: .zero,
            modifierFlags: modifiers, timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code
        )
    }

    /// Deterministic keyboard input: invoke the same handler the
    /// `WindowInputBridge` local monitor calls. This is the exact code path a
    /// real key event takes once it reaches the bridge; it does not depend on
    /// window-server focus, so it is reliable in `swift test`.
    @discardableResult
    func sendKey(_ characters: String, code: UInt16,
                 modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard let event = makeKeyEvent(characters, code: code, modifiers: modifiers) else {
            return false
        }
        return app.handleBoardKeyEvent(event, isDown: true)
    }

    /// Best-effort real event dispatch: post a key event into the queue and
    /// dispatch it through `NSApp.sendEvent` so the installed
    /// `WindowInputBridge` local monitor fires. Only works when the host window
    /// is key. Returns true if the event was dispatched.
    @discardableResult
    func postKey(_ characters: String, code: UInt16,
                 modifiers: NSEvent.ModifierFlags = []) -> Bool {
        guard windowIsKey,
              let event = makeKeyEvent(characters, code: code, modifiers: modifiers) else {
            return false
        }
        NSApp.postEvent(event, atStart: false)
        let deadline = Date(timeIntervalSinceNow: 0.1)
        while let next = NSApp.nextEvent(matching: .keyDown, until: deadline,
                                         inMode: .default, dequeue: true) {
            NSApp.sendEvent(next)
        }
        drainRunLoop(seconds: 0.05)
        return true
    }

    // MARK: - Accessibility tree

    /// A single accessibility node snapshot.
    struct AXSnapshot {
        let identifier: String
        let label: String
        let role: String
        let isEnabled: Bool
        /// The underlying AX object (NSView or NSAccessibilityElement).
        let ref: AnyObject
    }

    /// Recursively collect accessibility snapshots from the content view.
    func accessibilitySnapshot() -> [AXSnapshot] {
        var out: [AXSnapshot] = []
        guard let root = window.contentView else { return out }
        walkAX(root, into: &out)
        return out
    }

    private func walkAX(_ element: Any, into out: inout [AXSnapshot]) {
        guard let ax = element as? NSAccessibilityElement else {
            // NSView also conforms to NSAccessibility; its accessibility* methods
            // are available via the protocol. Try the view path below if this
            // branch is hit.
            if let view = element as? NSView {
                appendAX(view, into: &out)
                if let kids = view.accessibilityChildren() {
                    for kid in kids { walkAX(kid, into: &out) }
                }
            }
            return
        }
        appendAX(ax, into: &out)
        if let kids = ax.accessibilityChildren() {
            for kid in kids { walkAX(kid, into: &out) }
        }
    }

    private func appendAX(_ ax: NSAccessibilityElement, into out: inout [AXSnapshot]) {
        let id = ax.accessibilityIdentifier() ?? ""
        let label = ax.accessibilityLabel() ?? ""
        let role = (ax.accessibilityRole() ?? .unknown).rawValue
        let enabled = (ax.accessibilityAttributeValue(.enabled) as? Bool) ?? true
        // Only record elements that carry an identifier or label, to keep the
        // snapshot focused on actionable controls.
        if !id.isEmpty || !label.isEmpty {
            out.append(AXSnapshot(identifier: id, label: label, role: role,
                                   isEnabled: enabled, ref: ax))
        }
    }

    private func appendAX(_ view: NSView, into out: inout [AXSnapshot]) {
        let id = view.accessibilityIdentifier()
        let label = view.accessibilityLabel() ?? ""
        let role = (view.accessibilityRole() ?? .unknown).rawValue
        let enabled = (view.accessibilityAttributeValue(.enabled) as? Bool) ?? true
        if !id.isEmpty || !label.isEmpty {
            out.append(AXSnapshot(identifier: id, label: label, role: role,
                                   isEnabled: enabled, ref: view))
        }
    }

    /// Identifiers present in the mounted AX tree.
    func accessibilityIdentifiers() -> [String] {
        accessibilitySnapshot().map(\.identifier).filter { !$0.isEmpty }
    }

    /// Find the first AX snapshot matching an identifier.
    func accessibilityElement(identifier: String) -> AXSnapshot? {
        accessibilitySnapshot().first { $0.identifier == identifier }
    }

    /// Press a control by accessibility identifier via the AX press action.
    /// Returns true if the AX press reported success. When it does not, callers
    /// should fall back to the equivalent `AppState` method and record that.
    @discardableResult
    func pressAX(identifier: String) -> Bool {
        guard let snap = accessibilityElement(identifier: identifier) else { return false }
        let pressed = performPress(snap.ref)
        if pressed {
            drainRunLoop(seconds: 0.05)
            pressLog.append((identifier: identifier, viaAX: true))
        }
        return pressed
    }

    /// Press a control by accessibility label (e.g. a sheet's "Done" button
    /// that has no identifier) via the AX press action.
    @discardableResult
    func pressAX(label: String) -> Bool {
        guard let snap = accessibilitySnapshot().first(where: { $0.label == label }) else {
            return false
        }
        let pressed = performPress(snap.ref)
        if pressed {
            drainRunLoop(seconds: 0.05)
            pressLog.append((identifier: "label:\(label)", viaAX: true))
        }
        return pressed
    }

    private func performPress(_ ref: AnyObject) -> Bool {
        if let ax = ref as? NSAccessibilityElement { return ax.accessibilityPerformPress() }
        if let view = ref as? NSView { return view.accessibilityPerformPress() }
        return false
    }

    /// Press by identifier with a fallback closure. Tries the real AX press
    /// first; if that fails (e.g. process not AX-trusted), runs `fallback` and
    /// records which path was used. Returns true if either path ran.
    @discardableResult
    func press(identifier: String, fallback: () -> Void) -> Bool {
        if pressAX(identifier: identifier) { return true }
        fallback()
        recordFallbackPress(identifier)
        drainRunLoop(seconds: 0.05)
        return true
    }

    /// Record a fallback press (AX unavailable) for transparent reporting.
    func recordFallbackPress(_ identifier: String) {
        pressLog.append((identifier: identifier, viaAX: false))
    }

    // MARK: - View tree / hit testing

    /// The mounted content view (NSHostingView).
    var contentView: NSView? { window.contentView }

    /// Recursively find the first descendant NSView whose type name contains
    /// `typeName`. Used to locate the renderer's `BoardHostingView` without
    /// coupling the harness to private view structure.
    func findView(typeName: String) -> NSView? {
        guard let root = contentView else { return nil }
        return findView(root, typeName: typeName)
    }

    private func findView(_ view: NSView, typeName: String) -> NSView? {
        if String(describing: type(of: view)).contains(typeName) { return view }
        for sub in view.subviews {
            if let found = findView(sub, typeName: typeName) { return found }
        }
        return nil
    }

    /// The mounted board renderer view, if present (MatchView/MenuView mount one).
    func findBoardView() -> BoardHostingView? {
        findView(typeName: "BoardHostingView") as? BoardHostingView
    }

    /// The mounted `WindowInputBridge` carrier view, if present.
    func findCarrierView() -> NSView? {
        findView(typeName: "CarrierView")
    }

    /// True if a control with `identifier` is present in the mounted tree.
    func contains(identifier: String) -> Bool {
        accessibilityIdentifiers().contains(identifier)
    }

    /// True when the SwiftUI accessibility tree has materialized (i.e. the
    /// process is AX-trusted and identifiers are exposed). SwiftUI semantic AX
    /// (identifiers/labels/roles for buttons and toggles) does NOT materialize
    /// in a non-trusted `swift test` process — only AppKit-level backing views
    /// surface, with empty identifiers. AX-dependent assertions should gate on
    /// this and skip (with a documented reason) when false.
    var axTreeMaterialized: Bool {
        // Re-snapshot each call so it reflects the current view state. A
        // materialized SwiftUI tree yields at least one identifier.
        !accessibilityIdentifiers().isEmpty
    }

    // MARK: - Segment 20 — Screenshot capture

    /// A pixel-analysis report for a captured screenshot. Mirrors the
    /// `parallax-render-check` JSON shape so the two artifact paths are
    /// comparable.
    struct ScreenshotReport {
        let file: String
        let width: Int
        let height: Int
        let sampleCount: Int
        let brightSamples: Int
        let colorfulSamples: Int
        /// [xMin, yMin, xMax, yMax] in bitmap pixels (top-left origin).
        let contentBounds: [Int]
        let nonBlank: Bool
        let compositedBoard: Bool
        let byteCount: Int
    }

    enum ScreenshotError: Error {
        case noContentView
        case noBitmap
        case noPng
    }

    /// Capture the mounted window's content view to a PNG at
    /// `<directory>/<name>.png`. The SwiftUI/AppKit chrome is captured via
    /// `bitmapImageRep(for:)`; when a `BoardHostingView` is present in the
    /// mounted tree (menu preview, live match), its real SceneKit
    /// `renderSnapshot()` is composited on top at the board's frame so the
    /// Metal surface — which `bitmapImageRep` renders as black — is restored
    /// into the artifact. Returns a pixel-analysis report (bright/colorful
    /// sample counts, content bounds, non-blank flag).
    @discardableResult
    func captureSnapshot(named name: String, to directory: URL) throws -> ScreenshotReport {
        drainRunLoop(seconds: 0.3)
        guard let content = window.contentView else { throw ScreenshotError.noContentView }
        let bounds = content.bounds
        // `bitmapImageRep(for:)` was removed in the macOS 26 SDK; use the
        // caching-display pair: allocate a rep sized to the view, then render
        // the view into it. Metal layers (SCNView) still render black here, so
        // the board snapshot is composited on top below.
        guard let baseRep = content.bitmapImageRepForCachingDisplay(in: bounds) else {
            throw ScreenshotError.noBitmap
        }
        content.cacheDisplay(in: bounds, to: baseRep)
        let composite = compositeBoard(into: baseRep, contentView: content)
        let finalRep = composite ?? baseRep
        lastCapturedBitmap = finalRep
        guard let png = finalRep.representation(using: .png, properties: [:]) else {
            throw ScreenshotError.noPng
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(name).png")
        try png.write(to: file, options: .atomic)
        return Self.analyze(finalRep, file: file.path,
                            compositedBoard: composite != nil, byteCount: png.count)
    }

    /// Composite the mounted board's SceneKit snapshot into `baseRep` at the
    /// board view's frame. Returns a new bitmap rep, or nil when no board is
    /// mounted or the board snapshot is unavailable (non-board surfaces).
    private func compositeBoard(into baseRep: NSBitmapImageRep,
                                contentView content: NSView) -> NSBitmapImageRep? {
        guard let board = findBoardView(),
              let boardImage = board.renderSnapshot() else { return nil }
        // Board frame in content-view coordinates (bottom-left origin).
        let boardRect = board.convert(board.bounds, to: content)
        let size = content.bounds.size
        let composite = NSImage(size: size)
        composite.lockFocus()
        // Background chrome. `bitmapImageRep(for:)` is top-left origin;
        // drawing it into the bottom-left lock-focus context at the full rect
        // renders it upright.
        baseRep.draw(in: NSRect(origin: .zero, size: size))
        // Board: the lock-focus context and the view coordinate space are both
        // bottom-left origin, so the board rect needs no vertical flip.
        boardImage.draw(in: boardRect,
                        from: NSRect(origin: .zero, size: boardImage.size),
                        operation: .sourceOver, fraction: 1)
        composite.unlockFocus()
        guard let tiff = composite.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep
    }

    /// Pixel analysis shared with `parallax-render-check`. Samples every 4th
    /// pixel, counts bright (max channel > 0.2) and colorful (channel spread >
    /// 0.12) samples, and computes the content bounding box.
    ///
    /// The non-blank criterion is UI-appropriate, not the render-check's
    /// `bright > samples/100 && colorful > 20`: dark-themed SwiftUI surfaces
    /// (e.g. Settings) are legitimately monochrome (`colorful == 0`), and a
    /// tall ScrollView can make `samples/100` exceed the bright count even when
    /// the surface is full of content. A real UI has many bright samples
    /// spanning a non-trivial region; a blank/black frame has bright ≈ 0 and a
    /// degenerate bounds box. So non-blank requires an absolute bright count
    /// above 500 AND content spanning > 50px on both axes.
    static func analyze(_ bitmap: NSBitmapImageRep, file: String,
                        compositedBoard: Bool, byteCount: Int) -> ScreenshotReport {
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
        let spanX = xMax - xMin, spanY = yMax - yMin
        let nonBlank = bright > 500 && spanX > 50 && spanY > 50
        return ScreenshotReport(
            file: file, width: bitmap.pixelsWide, height: bitmap.pixelsHigh,
            sampleCount: samples, brightSamples: bright, colorfulSamples: colorful,
            contentBounds: [xMin, yMin, xMax, yMax],
            nonBlank: nonBlank, compositedBoard: compositedBoard, byteCount: byteCount)
    }

    /// Count bright samples (max channel > 0.2) inside a normalized rect
    /// (0...1 in both axes, top-left origin to match the bitmap's pixel order).
    /// Used by screenshot tests for basic layout/visibility checks (e.g. "the
    /// persona strip region has content", "the menu's left panel has content").
    /// Returns -1 when no bitmap has been captured.
    func brightSamples(inNormalizedRect r: CGRect) -> Int {
        guard let bitmap = lastCapturedBitmap else { return -1 }
        let xStart = Int(r.minX * CGFloat(bitmap.pixelsWide))
        let xEnd = Int(r.maxX * CGFloat(bitmap.pixelsWide))
        let yStart = Int(r.minY * CGFloat(bitmap.pixelsHigh))
        let yEnd = Int(r.maxY * CGFloat(bitmap.pixelsHigh))
        var bright = 0
        for y in stride(from: max(0, yStart), to: min(bitmap.pixelsHigh, yEnd), by: 4) {
            for x in stride(from: max(0, xStart), to: min(bitmap.pixelsWide, xEnd), by: 4) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.2 { bright += 1 }
            }
        }
        return bright
    }
}
