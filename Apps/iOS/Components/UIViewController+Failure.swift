import LuxCore
import UIKit

extension UIViewController {
    /// Logs a failed action, and tells the user when only they can change it (a label's name
    /// taken, a time passed); passing trouble only goes to the log.
    func report(_ error: any Error, of what: String) {
        Log.app.error("\(what, privacy: .public): \(String(describing: error), privacy: .public)")
        guard let failure = error as? AccountFailure, failure.isForTheUser, presentedViewController == nil else { return }
        let alert = UIAlertController(title: nil, message: failure.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
