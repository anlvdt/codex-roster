import AppKit
import SwiftUI

extension Notification.Name {
    /// Collapse the notch panel so utility windows are not covered by `.statusBar`.
    static let collapseNotchPanel = Notification.Name("codexRoster.collapseNotchPanel")
}

/// Presentation helpers so Settings / About / sheets sit above the notch panel.
@MainActor
enum RosterWindowSurface {
    /// Notch uses `.statusBar` (25). Utility windows must be strictly higher.
    static let aboveNotch = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// Open/elevate a named SwiftUI `Window` above the notch and collapse the panel first.
    static func presentNamedWindow(id: String) {
        NotificationCenter.default.post(name: .collapseNotchPanel, object: nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
        elevateNamedWindow(id: id)
        DispatchQueue.main.async {
            elevateNamedWindow(id: id)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            elevateNamedWindow(id: id)
        }
    }

    static func elevateNamedWindow(id: String) {
        for window in NSApplication.shared.windows where window.identifier?.rawValue == id {
            guard window.identifier?.rawValue != "notch" else { continue }
            window.level = aboveNotch
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// Elevate a sheet / child window that was presented from the notch host.
    static func elevatePresentedWindow(_ window: NSWindow?) {
        guard let window else { return }
        if window.identifier?.rawValue == "notch" { return }
        window.level = aboveNotch
        window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}

/// Attach to sheet content so the sheet window rises above the `.statusBar` notch.
struct ElevatePresentedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            RosterWindowSurface.elevatePresentedWindow(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            RosterWindowSurface.elevatePresentedWindow(nsView.window)
        }
    }
}
