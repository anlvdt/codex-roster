import AppKit
import ApplicationServices
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
        guard CodexResumePolicy.readQueue(threadID: threadID) == .owned,
              let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              ChatGPTDesktop.resolvableBundleIDs().contains(bundleID) else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(root, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value else { return false }
        let window = value as! AXUIElement
        var nodes: [(AXUIElement, String, String, Bool)] = []
        collect(window, depth: 0, nodes: &nodes)
        let text = nodes.map { $0.2 }.joined(separator: "\n")
        guard text.contains(CodexResumePolicy.marker(threadID)),
              text.contains("Queue paused because you interrupted")
                || text.localizedCaseInsensitiveContains("hàng đợi") && text.localizedCaseInsensitiveContains("tạm dừng"),
              !nodes.contains(where: { $0.1 == kAXButtonRole as String && ["stop", "stop response", "dừng"].contains($0.2.lowercased()) }),
              !nodes.contains(where: { [kAXTextAreaRole as String, kAXTextFieldRole as String].contains($0.1) && !$0.2.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { return false }
        let buttons = nodes.filter { $0.1 == kAXButtonRole as String && $0.3 && CodexResumePolicy.isResumeLabel($0.2) }
        guard buttons.count == 1, CodexResumePolicy.readQueue(threadID: threadID) == .owned else { return false }
        let result = AXUIElementPerformAction(buttons[0].0, kAXPressAction as CFString)
        log("native Resume requested for marked thread; AX status=\(result.rawValue) (not confirmation of turn start)")
        return result == .success
    }

    private static func collect(_ element: AXUIElement, depth: Int, nodes: inout [(AXUIElement, String, String, Bool)]) {
        guard depth < 24, nodes.count < 4000 else { return }
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
