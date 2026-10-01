import AppKit
import ApplicationServices

struct FieldState: Equatable {
    let process: pid_t
    let value: String
    let selectionStart: Int
    let selectionLength: Int
    let secure: Bool
    func allowsPaste(from previous: Self) -> Bool { !secure && !previous.secure && self == previous }
}

@MainActor final class PasteCoordinator {
    private var element: AXUIElement?
    private var before: FieldState?

    private func read(_ name: String, from element: AXUIElement) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func focused(in process: pid_t) -> AXUIElement? {
        guard let value = read(kAXFocusedUIElementAttribute, from: AXUIElementCreateApplication(process)),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
    private func snapshot(of element: AXUIElement, process: pid_t) -> FieldState? {
        guard let role = read(kAXRoleAttribute, from: element) as? String,
              [kAXTextAreaRole, kAXTextFieldRole, kAXComboBoxRole].contains(role),
              let value = read(kAXValueAttribute, from: element) as? String,
              let range = read(kAXSelectedTextRangeAttribute, from: element), CFGetTypeID(range) == AXValueGetTypeID() else { return nil }
        var selected = CFRange()
        guard AXValueGetValue(range as! AXValue, .cfRange, &selected) else { return nil }
        return FieldState(process: process, value: value, selectionStart: selected.location, selectionLength: selected.length,
            secure: (read(kAXSubroleAttribute, from: element) as? String) == kAXSecureTextFieldSubrole)
    }
    func capture() {
        reset()
        guard AXIsProcessTrusted(), let process = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              process != ProcessInfo.processInfo.processIdentifier, let focused = focused(in: process),
              let state = snapshot(of: focused, process: process), !state.secure else { return }
        element = focused; before = state
    }
    func paste() -> Bool {
        defer { reset() }
        guard AXIsProcessTrusted(), let before, let element,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == before.process,
              let current = focused(in: before.process), CFEqual(element, current),
              let state = snapshot(of: current, process: before.process), state.allowsPaste(from: before),
              let source = CGEventSource(stateID: .combinedSessionState),
              let press = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let release = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        press.flags = .maskCommand; release.flags = .maskCommand
        press.post(tap: .cghidEventTap); release.post(tap: .cghidEventTap)
        return true
    }
    func reset() { before = nil; element = nil }
}
