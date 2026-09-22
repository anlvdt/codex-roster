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
            if id == RosterConsoleTab.windowID {
                window.title = consoleWindowTitle()
            }
            window.level = aboveNotch
            window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    /// SwiftUI `Window(title:)` freezes the first-evaluated string; keep AppKit in sync.
    static func consoleWindowTitle() -> String {
        AppLanguage.text("Bảng điều khiển", "Roster Console")
    }

    static func syncConsoleWindowTitle(_ title: String? = nil) {
        let resolved = title ?? consoleWindowTitle()
        for window in NSApplication.shared.windows where window.identifier?.rawValue == RosterConsoleTab.windowID {
            window.title = resolved
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

/// Keeps a named SwiftUI `Window` chrome title in sync when UI language changes.
struct SyncNamedWindowTitle: NSViewRepresentable {
    let title: String
    let windowID: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { apply(from: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { apply(from: nsView) }
    }

    private func apply(from view: NSView) {
        if let window = view.window {
            window.title = title
        }
        for window in NSApplication.shared.windows where window.identifier?.rawValue == windowID {
            window.title = title
        }
    }
}
