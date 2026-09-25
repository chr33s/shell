import UIKit

// The terminal is a byte stream with no editable document, but UIKit's text
// input machinery (CJK/Korean IME composition and dictation) needs an accurate
// picture of what it believes the field contains. `correctionContext` owns that
// committed document; this file keeps it in step with terminal-side events.
//
// docs/specs/shell.md §2.2 removes the writing assistant (autocorrect / QuickType rewriting),
// so spelling and autocorrection traits stay off and nothing here grants UIKit
// authority to rewrite committed text. Only the document bookkeeping remains.
extension Ghostty.TerminalView {
    func setupInputDocument() {
        spellCheckingType = .no
        autocorrectionType = .no
    }

    func requestInputDocumentRequery() {
        guard !inputDocumentRequeryPending else { return }
        inputDocumentRequeryPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.inputDocumentRequeryPending = false
            // A tab handoff resets both terminals' documents. By the time this
            // deferred callback runs, only the new responder owns UIKit's
            // input session; notifying the old delegate starts unnecessary
            // keyboard work and can query the wrong document during the switch.
            guard self.isFirstResponder, self.window != nil else { return }
            self.notifyInputDelegateOfExternalChange { }
        }
    }

    func invalidateInputDocument(resetDocument: Bool = false) {
        mutateInputDocument(resetDocument ? .reset : .invalidate)
        clearBulkDictationFallback()
        if resetDocument {
            lastDictationActivityAt = nil
            pendingDictationPlaceholderTokens.removeAll()
        }
    }

    /// A rejected UIKit edit needs a fresh document even if its authority was
    /// already revoked. Ordinary repeated scroll invalidations do not.
    func rejectInputDocumentReplacement() {
        invalidateInputDocument()
        requestInputDocumentRequery()
    }

    func clearBulkDictationFallback() {
        lastBulkTextInputAt = nil
        bulkDictationRange = nil
        bulkDictationDocumentGeneration = nil
    }

    @discardableResult
    func mutateInputDocument(_ mutation: TerminalCorrectionContext.Mutation) -> Bool {
        let generation = correctionContext.generation
        let documentGeneration = correctionContext.documentGeneration
        guard correctionContext.apply(mutation) else { return false }
        if case .invalidate = mutation {} else {
            clearBulkDictationFallback()
        }
        if generation != correctionContext.generation || documentGeneration != correctionContext.documentGeneration {
            // Resets before focus acquisition are read by UIKit when it
            // installs the new responder. Only an existing input session
            // needs a subsequent external-document-change notification.
            if isFirstResponder {
                requestInputDocumentRequery()
            }
        }
        return true
    }
}
