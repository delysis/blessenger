import Darwin
import Foundation

/// Qualification-only recorder. Sample the active save/inference overlap and
/// retain the kernel's process-lifetime high-water marks independently.
final class PeakMemoryRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "CallGemma.Qualification.Memory")
    private let timer: DispatchSourceTimer
    private var peak: UInt64 = 0
    private var rss: UInt64 = 0
    private var kernelPeak: UInt64 = 0
    private var kernelRSS: UInt64 = 0
    private var samples = 0

    init() {
        timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
    }

    deinit { timer.cancel() }

    func stop() -> [String: UInt64] {
        timer.cancel()
        return queue.sync {
            sample()
            return ["sampled_peak_footprint_bytes": peak, "sampled_peak_rss_bytes": rss,
                    "kernel_lifetime_peak_footprint_bytes": kernelPeak,
                    "kernel_lifetime_peak_rss_bytes": kernelRSS, "samples": UInt64(samples)]
        }
    }

    private func sample() {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }
        samples += 1
        peak = max(peak, UInt64(info.phys_footprint))
        rss = max(rss, UInt64(info.resident_size))
        kernelPeak = max(kernelPeak, UInt64(max(0, info.ledger_phys_footprint_peak)))
        kernelRSS = max(kernelRSS, UInt64(info.resident_size_peak))
    }
}
