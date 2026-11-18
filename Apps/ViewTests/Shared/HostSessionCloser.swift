import Foundation
@testable import Lux
import LuxCore
import XCTest

/// The app hosting the view tests runs a demo session of its own (`-LuxDemo`), and XCTest exits
/// the process once the bundle's tests are done, without the app's own ending: the session
/// closes here first, its stores' threads ended before the exit, as the app's are when it quits.
/// The bundle's principal class (`NSPrincipalClass`, project.yml): XCTest makes it as it loads
/// the bundle, before the tests run.
@objc(HostSessionCloser)
final class HostSessionCloser: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        MainActor.assumeIsolated {
            Self.hostSession?.closeBeforeReturning(within: .seconds(10))
        }
    }

    @MainActor private static var hostSession: Session? {
        #if os(iOS)
        AppDelegate.session
        #else
        (NSApplication.shared.delegate as? AppDelegate)?.session
        #endif
    }
}
