import AppKit

/// Resetting Miku's memory takes two deliberate steps:
/// 1. A warning that lists exactly what she will forget (Cancel is the default button).
/// 2. Typing a confirmation word ("重設" / "RESET" / "リセット") before the reset button works.
/// A backup is kept, so a reset can still be undone from Settings afterwards.
@MainActor
enum MemoryResetConfirmation {
    /// Runs both steps as app-modal alerts. Returns true only if the user confirmed twice.
    static func confirm() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let memory = CompanionMemory.shared
        let summary = memory.resetSummary

        // Step 1: what will be lost.
        let warning = NSAlert()
        warning.alertStyle = .critical
        warning.messageText = L10n.text("memoryEraseConfirm")
        warning.informativeText = L10n.format(
            "memoryEraseSummary",
            String(summary.messages),
            String(summary.facts),
            String(summary.friendship),
            String(summary.daysKnown)
        ) + "\n\n" + L10n.text("memoryEraseDetail")
        warning.addButton(withTitle: L10n.text("cancel"))
        let next = warning.addButton(withTitle: L10n.text("memoryEraseContinue"))
        next.hasDestructiveAction = true
        guard warning.runModal() == .alertSecondButtonReturn else { return false }

        // Step 2: type the word.
        let word = L10n.text("memoryEraseWord")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = word
        let typed = NSAlert()
        typed.alertStyle = .critical
        typed.messageText = L10n.text("memoryEraseTypeTitle")
        typed.informativeText = L10n.format("memoryEraseTypeDetail", word)
        typed.accessoryView = field
        typed.addButton(withTitle: L10n.text("cancel"))
        let erase = typed.addButton(withTitle: L10n.text("memoryErase"))
        erase.hasDestructiveAction = true
        typed.window.initialFirstResponder = field
        guard typed.runModal() == .alertSecondButtonReturn else { return false }

        let answer = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard answer.compare(word, options: [.caseInsensitive, .widthInsensitive]) == .orderedSame else {
            let mismatch = NSAlert()
            mismatch.messageText = L10n.text("memoryEraseMismatch")
            mismatch.addButton(withTitle: "OK")
            mismatch.runModal()
            return false
        }
        return true
    }

    /// Confirms twice, then resets. Returns whether memory was erased.
    @discardableResult
    static func run() -> Bool {
        guard confirm() else { return false }
        guard CompanionMemory.shared.eraseAll() else {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L10n.text("memoryOperationFailed")
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        return true
    }
}
