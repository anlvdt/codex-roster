import AppKit
import ApplicationServices
import Foundation

/// Newer Codex Desktop builds replace auto-start with an explicit composer
/// **Play** control ("Queued messages run now" / resume after interrupt).
/// `codex queue` alone leaves the turn waiting for that press.
@MainActor
enum CodexComposerPlay {
    /// Activate ChatGPT/Codex Desktop and trigger Play (or Return as fallback).
    @discardableResult
    static func press(log: (String) -> Void = { _ in }) async -> Bool {
        requestAccessibilityIfNeeded()
        guard activateDesktop(log: log) else {
            log("composer Play: Desktop not running")
            return false
        }
        // Let the focused thread / queued chip settle after deep-link or queue.
        try? await Task.sleep(for: .milliseconds(350))

        if pressPlayViaAccessibility(log: log) {
            return true
        }
        if pressReturnKey(log: log) {
            return true
        }
        if clickComposerTrailingAction(log: log) {
            return true
        }
        log("composer Play: all strategies failed")
        return false
    }

    private static func requestAccessibilityIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        // CFString global is not Sendable under Swift 6; use the documented key literal.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private static func activateDesktop(log: (String) -> Void) -> Bool {
        let apps = ChatGPTDesktop.resolvableBundleIDs()
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let app = apps.first(where: { !$0.isTerminated }) else {
            return false
        }
        let ok = app.activate()
        log("composer Play: activate pid=\(app.processIdentifier) ok=\(ok)")
        return ok
    }

    /// Prefer a real Play / run-now control when Accessibility can see it.
    private static func pressPlayViaAccessibility(log: (String) -> Void) -> Bool {
        let trusted = AXIsProcessTrusted()
        guard trusted else {
            log("composer Play: Accessibility not trusted — skip AX")
            return false
        }
        let apps = ChatGPTDesktop.resolvableBundleIDs()
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let app = apps.first(where: { !$0.isTerminated }) else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var match: AXUIElement?
        findPlayButton(in: appElement, depth: 0, maxDepth: 12, found: &match)
        guard let button = match else {
            log("composer Play: no AX Play/run-now button")
            return false
        }
        let err = AXUIElementPerformAction(button, kAXPressAction as CFString)
        log("composer Play: AXPress status=\(err.rawValue)")
        return err == .success
    }

    private static func findPlayButton(
        in element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        found: inout AXUIElement?
    ) {
        if found != nil || depth > maxDepth { return }

        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        let title = axString(element, kAXTitleAttribute as CFString) ?? ""
        let description = axString(element, kAXDescriptionAttribute as CFString) ?? ""
        let help = axString(element, kAXHelpAttribute as CFString) ?? ""
        let identifier = axString(element, "AXIdentifier" as CFString) ?? ""
        let blob = "\(title) \(description) \(help) \(identifier)".lowercased()

        let looksLikePlay =
            blob.contains("play")
            || blob.contains("run now")
            || blob.contains("runnow")
            || blob.contains("queued messages run")
            || (blob.contains("queue") && blob.contains("run"))
            || blob.contains("resume")
            || identifier.lowercased().contains("composer") && blob.contains("submit")

        if looksLikePlay, role == (kAXButtonRole as String) || role.contains("Button") {
            found = element
            return
        }

        var childrenObject: AnyObject?
        let childStatus = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenObject
        )
        guard childStatus == .success,
              let children = childrenObject as? [AXUIElement] else { return }
        for child in children {
            findPlayButton(in: child, depth: depth + 1, maxDepth: maxDepth, found: &found)
            if found != nil { return }
        }
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// Composer submit / Play is usually bound to Return when the thread is focused.
    private static func pressReturnKey(log: (String) -> Void) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false)
        guard let keyDown, let keyUp else {
            log("composer Play: could not create Return events")
            return false
        }
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        log("composer Play: posted Return")
        return true
    }

    /// Last resort: click the trailing circular action in the composer row
    /// (Play sits bottom-right next to the mic on current Desktop builds).
    private static func clickComposerTrailingAction(log: (String) -> Void) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let apps = ChatGPTDesktop.resolvableBundleIDs()
            .flatMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0) }
        guard let app = apps.first(where: { !$0.isTerminated }) else { return false }
        // Prefer the front window frame when available.
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let owned = windowList.filter {
            ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier
                && ($0[kCGWindowLayer as String] as? Int) == 0
        }
        guard let bounds = owned.first?[kCGWindowBounds as String] as? [String: CGFloat],
              let x = bounds["X"], let y = bounds["Y"],
              let w = bounds["Width"], let h = bounds["Height"],
              w > 200, h > 200 else {
            log("composer Play: no usable Desktop window bounds")
            return false
        }
        // Bottom-right composer action — inset from the trailing edge.
        let clickX = x + w - 36
        let clickY = y + h - 42
        let point = CGPoint(x: clickX, y: clickY)
        guard point.x > screen.frame.minX, point.y > screen.frame.minY else { return false }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left) else {
            return false
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        log("composer Play: clicked trailing composer point=(\(Int(clickX)),\(Int(clickY)))")
        return true
    }
}
