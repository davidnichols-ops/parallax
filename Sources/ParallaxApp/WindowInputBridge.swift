import AppKit
import SwiftUI

/// One local keyboard monitor per mounted game window. It remains independent
/// of the board's first-responder status and is removed by both AppKit and
/// SwiftUI view lifecycle callbacks.
public struct WindowInputBridge: NSViewRepresentable {
    let app: AppState

    public init(app: AppState) { self.app = app }

    public func makeNSView(context: Context) -> CarrierView { CarrierView(app: app) }

    public func updateNSView(_ view: CarrierView, context: Context) {
        view.app = app
        view.ensureMonitorInstalled()
    }

    public static func dismantleNSView(_ view: CarrierView, coordinator: ()) {
        view.removeMonitor()
    }

    @MainActor
    public final class CarrierView: NSView {
        var app: AppState
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []
        private weak var monitoredWindow: NSWindow?

        init(app: AppState) {
            self.app = app
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("Not supported") }

        public override func hitTest(_ point: NSPoint) -> NSView? { nil }

        public override func viewWillMove(toWindow newWindow: NSWindow?) {
            if monitoredWindow !== newWindow { removeMonitor() }
            super.viewWillMove(toWindow: newWindow)
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window != nil { ensureMonitorInstalled() } else { removeMonitor() }
        }

        func ensureMonitorInstalled() {
            guard let window else { return }
            if monitoredWindow !== window { removeMonitor() }
            guard monitor == nil else { return }
            monitoredWindow = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                // AppKit invokes local event monitors synchronously on its main
                // event loop, so this is an explicit checked actor boundary.
                let handled = MainActor.assumeIsolated {
                    guard let self, event.window === self.monitoredWindow,
                          self.monitoredWindow?.isKeyWindow == true,
                          !event.modifierFlags.contains(.command),
                          !event.modifierFlags.contains(.control),
                          !self.isEditingText else { return false }
                    return self.app.handleBoardKeyEvent(event, isDown: event.type == .keyDown)
                }
                return handled ? nil : event
            }
            for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] notification in
                    let closesWindow = notification.name == NSWindow.willCloseNotification
                    MainActor.assumeIsolated {
                        self?.app.releaseBoardInput()
                        if closesWindow { self?.removeMonitor() }
                    }
                })
            }
            observers.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.app.releaseBoardInput() }
            })
        }

        func removeMonitor() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            monitoredWindow = nil
            app.releaseBoardInput()
        }

        private var isEditingText: Bool {
            guard let responder = monitoredWindow?.firstResponder else { return false }
            if let text = responder as? NSTextView, text.isEditable { return true }
            return responder is NSTextField || responder is NSComboBox
        }

        var installedMonitorCount: Int { monitor == nil ? 0 : 1 }
    }
}
