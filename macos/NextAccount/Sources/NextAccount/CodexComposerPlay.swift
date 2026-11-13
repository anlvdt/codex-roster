import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Resume only the marked Roster message in the focused native paused queue.
@MainActor
enum CodexComposerPlay {
    @discardableResult
    static func press(threadID: String, log: (String) -> Void = { _ in }) async -> Bool {
        guard AXIsProcessTrusted() else {
            log("queue accepted; Accessibility unavailable — use native Resume")
            return false
        }
        for _ in 0..<8 {
            guard !Task.isCancelled else { return false }
            if pressPlayViaAccessibility(threadID: threadID, log: log) { return true }
            try? await Task.sleep(for: .milliseconds(400))
        }
        log("queue accepted; no verified enabled Resume — native queue remains in control")
        return false
    }

    private static func pressPlayViaAccessibility(threadID: String, log: (String) -> Void) -> Bool {
        guard CodexResumePolicy.readQueue(threadID: threadID) == .owned else { return false }
        // Prefer the Desktop process even when Roster is frontmost after switch.
        let app = NSWorkspace.shared.runningApplications.first(where: {
            guard let bundleID = $0.bundleIdentifier else { return false }
            return ChatGPTDesktop.resolvableBundleIDs().contains(bundleID)
        }) ?? {
            guard let front = NSWorkspace.shared.frontmostApplication,
                  let bundleID = front.bundleIdentifier,
                  ChatGPTDesktop.resolvableBundleIDs().contains(bundleID) else { return nil }
            return front
        }()
        guard let app else { return false }
        app.activate(options: [])
        let root = AXUIElementCreateApplication(app.processIdentifier)
        // Electron/OWL hides most of the tree until this is set.
        AXUIElementSetAttributeValue(
            root,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )

        var windowsObj: AnyObject?
        let windows: [AXUIElement]
        if AXUIElementCopyAttributeValue(root, kAXWindowsAttribute as CFString, &windowsObj) == .success,
           let listed = windowsObj as? [AXUIElement], !listed.isEmpty {
            windows = listed
        } else {
            var focused: AnyObject?
            guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &focused) == .success,
                  let focused else { return false }
            windows = [focused as! AXUIElement]
        }
        var nodes: [(AXUIElement, String, String, Bool)] = []
        for window in windows {
            collect(window, depth: 0, nodes: &nodes)
        }
        let text = nodes.map { $0.2 }.joined(separator: "\n")
        let hasStop = nodes.contains(where: {
            $0.1 == kAXButtonRole as String
                && ["stop", "stop response", "dừng"].contains($0.2.lowercased())
        })
        // Placeholder composer text must not count as a user draft.
        let hasDraft = nodes.contains(where: {
            [kAXTextAreaRole as String, kAXTextFieldRole as String].contains($0.1)
                && !$0.2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.2.trimmingCharacters(in: .whitespacesAndNewlines) != "Work with Codex"
        })
        guard !hasStop, !hasDraft else { return false }
        let buttons = nodes.filter {
            $0.1 == kAXButtonRole as String && $0.3 && CodexResumePolicy.isResumeLabel($0.2)
        }
        guard let button = buttons.first,
              CodexResumePolicy.readQueue(threadID: threadID) == .owned else { return false }
        // Prefer evidence the paused queue is ours, but OWL often omits marker
        // text from AX labels even when queue_1.sqlite is owned — still press.
        let confirmedOwnedUI = text.contains(CodexResumePolicy.marker(threadID))
            || text.contains("Queue paused because you interrupted")
            || (text.localizedCaseInsensitiveContains("hàng đợi")
                && text.localizedCaseInsensitiveContains("tạm dừng"))
            || text.localizedCaseInsensitiveContains("Codex Roster auto-resume")
        if !confirmedOwnedUI {
            log("Resume UI weak AX evidence; trusting owned sqlite queue for \(threadID)")
        }

        // AXPress is a no-op on many OWL/Electron controls; click the frame.
        if clickFrameCenter(of: button.0) {
            log("native Resume clicked via CGEvent for marked thread; buttons=\(buttons.count)")
            return true
        }
        let result = AXUIElementPerformAction(button.0, kAXPressAction as CFString)
        log("native Resume AXPress fallback status=\(result.rawValue) buttons=\(buttons.count)")
        return result == .success
    }

    private static func clickFrameCenter(of element: AXUIElement) -> Bool {
        var positionValue: AnyObject?
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue else { return false }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size),
              size.width > 0, size.height > 0 else { return false }
        let point = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
        func post(_ type: CGEventType) {
            guard let event = CGEvent(
                mouseEventSource: nil,
                mouseType: type,
                mouseCursorPosition: point,
                mouseButton: .left
            ) else { return }
            event.post(tap: .cghidEventTap)
        }
        post(.mouseMoved)
        post(.leftMouseDown)
        post(.leftMouseUp)
        return true
    }

    private static func collect(_ element: AXUIElement, depth: Int, nodes: inout [(AXUIElement, String, String, Bool)]) {
        guard depth < 32, nodes.count < 8000 else { return }
        let role = axString(element, kAXRoleAttribute as CFString) ?? ""
        let label = role == kAXTextAreaRole as String || role == kAXTextFieldRole as String
            ? axString(element, kAXValueAttribute as CFString) ?? ""
            : [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute].compactMap { axString(element, $0 as CFString) }.first(where: { !$0.isEmpty }) ?? ""
        var enabled: AnyObject?
        _ = AXUIElementCopyAttributeValue(element, kAXEnabledAttribute as CFString, &enabled)
        nodes.append((element, role, label, (enabled as? Bool) == true))
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value) == .success,
              let children = value as? [AXUIElement] else { return }
        for child in children { collect(child, depth: depth + 1, nodes: &nodes) }
    }

    private static func axString(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }
}
