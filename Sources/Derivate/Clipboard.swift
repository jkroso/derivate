import AppKit

/// Copies passwords to the clipboard marked concealed
/// (org.nspasteboard.ConcealedType, nspasteboard.org): clipboard managers,
/// Paste among them, keep them out of their history.
@MainActor
enum Clipboard {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Puts the text on the clipboard and empties it after the delay,
    /// unless something else was copied since. A delay of nil keeps it.
    static func copySecret(_ text: String, clearAfter delay: Duration?) {
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(text, forType: .string)
        board.setString("", forType: concealed)
        guard let delay else { return }
        let count = board.changeCount
        Task {
            try? await Task.sleep(for: delay)
            if board.changeCount == count {
                board.clearContents()
            }
        }
    }
}
