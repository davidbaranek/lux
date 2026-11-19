import Foundation
import Network

/// Whether the user asked the device to save its battery (Low Power Mode) or its data (Low Data
/// Mode, on the network in use): heavy work that can wait, such as reading photos, waits. It
/// follows the network for that, so it also says when the device is back on one (`reconnected`).
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
    /// The device has a network again, after none: what failed for the want of one can be
    /// tried again.
    let reconnected = Broadcast()

    private var savesData = false
    private var isOnline = true
    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let constrained = path.isConstrained
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self else { return }
                if self.isOnline != online {
                    self.isOnline = online
                    if online { self.reconnected.send() }
                }
                guard self.savesData != constrained else { return }
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
