import Darwin
import Foundation

/// Memory facts from the kernel. Bytes throughout.
public enum Memory {
    /// A process's `phys_footprint` (includes unified/GPU memory), via `proc_pid_rusage`.
    public static func footprint(pid: pid_t) -> Int? {
        var info = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        return ok == 0 ? Int(info.ri_phys_footprint) : nil
    }

    /// What macOS itself counts as available (`kern.memorystatus_level`, the "free percentage" `memory_pressure`
    /// prints): free, inactive, cached files and compressible memory alike. Free + inactive pages alone miss
    /// tens of GB of reclaimable cache.
    @Sendable public static func systemFree() -> Int {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0, (1...100).contains(level) {
            return physical / 100 * Int(level)
        }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let kr = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return (Int(stats.free_count) + Int(stats.inactive_count)) * Int(getpagesize())
    }

    public static var physical: Int { Int(ProcessInfo.processInfo.physicalMemory) }
}
