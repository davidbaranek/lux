import AppKit
import LuxCore

extension NSViewController {
    /// Logs a failed action, and tells the user when only they can change it (a label's name
    /// taken, a time passed); passing trouble only goes to the log.
    func report(_ error: any Error, of what: String) {
        Log.app.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
        guard let failure = error as? AccountFailure, failure.isForTheUser, let window = view.window,
              window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = failure.localizedDescription
        alert.beginSheetModal(for: window)
    }
}
