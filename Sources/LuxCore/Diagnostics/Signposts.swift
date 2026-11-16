import Darwin
import Foundation
import os

public enum Log {
    public static let app = Logger(subsystem: AppIdentity.bundleId, category: "app")
    public static let metrics = Logger(subsystem: AppIdentity.bundleId, category: "metrics")
    /// The Rust core's own log (its `tracing` events), as `CoreLog` writes it.
    public static let core = Logger(subsystem: AppIdentity.bundleId, category: "core")
}

/// Intervals that Instruments (os_signpost) shows, under the app's bundle id as the subsystem.
public enum Signposts {
    public static let list = OSSignposter(subsystem: AppIdentity.bundleId, category: "list")
    public static let thread = OSSignposter(subsystem: AppIdentity.bundleId, category: "thread")
    public static let images = OSSignposter(subsystem: AppIdentity.bundleId, category: "images")

    /// Seconds since the process started (the kernel's start time), for "launch to first chats".
    public static func sinceProcessStart() -> Double {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        return Date().timeIntervalSince1970 - started
    }

    /// The app's resident memory (phys_footprint, what Xcode's gauge shows), in MB.
    public static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    @MainActor private static var reportedFirstChats = false

    /// Logs once, the first time the chat list shows chats.
    @MainActor
    public static func firstChatsShown(count: Int) {
        guard !reportedFirstChats else { return }
        reportedFirstChats = true
        let seconds = sinceProcessStart()
        list.emitEvent("first chats")
        Log.metrics.notice("launch-to-first-chats \(seconds, format: .fixed(precision: 3), privacy: .public) s, \(count, privacy: .public) chats, footprint \(footprintMB(), format: .fixed(precision: 1), privacy: .public) MB")
    }
}
