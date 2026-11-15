import Foundation
import Network

/// Whether the user asked the device to save its battery (Low Power Mode) or its data (Low Data
/// Mode, on the network in use): heavy work that can wait, such as reading photos, waits.
@MainActor
public final class Saving {
    public static let shared = Saving()

    /// What the device saves, if anything; nil when neither.
    public enum Reason: Sendable, Equatable {
        case battery
        case data
    }

    /// Why heavy work waits now; nil when it need not.
    public var reason: Reason? {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return .battery }
        return savesData ? .data : nil
    }

    public let changes = Broadcast()

    private var savesData = false
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            Task { @MainActor in
                guard let self, self.savesData != constrained else { return }
                self.savesData = constrained
                self.changes.send()
            }
        }
        monitor.start(queue: DispatchQueue(label: "lux.saving"))
        NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Saving.shared.changes.send() }
        }
    }
}
