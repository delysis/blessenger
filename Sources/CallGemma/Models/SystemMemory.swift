import Darwin
import Foundation

enum SystemMemory {
    static func sample() throws -> MemoryBudget {
        #if os(iOS)
        // iOS jetsam limits the process, independently of system-wide free RAM.
        return MemoryBudget(physicalBytes: ProcessInfo.processInfo.physicalMemory,
                            availableBytes: UInt64(os_proc_available_memory()))
        #else
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var pageSize: vm_size_t = 0
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        guard host_page_size(host, &pageSize) == KERN_SUCCESS else {
            throw ModelStoreError.memoryQueryFailed
        }
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw ModelStoreError.memoryQueryFailed }

        // Inactive pages are reclaimable, not guaranteed free. ModelPolicy keeps
        // a separate reserve. Speculative pages are already in free_count; do
        // not add them or purgeable_count again (xnu/mach/vm_statistics.h).
        let pages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        let (available, overflow) = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        guard !overflow else { throw ModelStoreError.memoryQueryFailed }
        return MemoryBudget(
            physicalBytes: ProcessInfo.processInfo.physicalMemory,
            availableBytes: available
        )
        #endif
    }
}
