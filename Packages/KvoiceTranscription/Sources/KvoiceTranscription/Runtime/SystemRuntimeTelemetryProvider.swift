import Darwin
import Foundation
import IOKit
import KvoiceDomain

/// `RuntimeTelemetryProviding` over Mach task info and the IOKit accelerator
/// registry. The only file in the project that touches Mach task counters or
/// IOKit; both stay here so the view model and the shell see three domain
/// scalars and nothing else (rule 1).
///
/// Why these sources:
/// - `task_info(TASK_VM_INFO).phys_footprint` is the figure Activity Monitor
///   shows as Memory and the one the model weights actually move.
/// - CPU is *this process's* consumed CPU time (`MACH_TASK_BASIC_INFO` for
///   threads that have exited plus `TASK_THREAD_TIMES_INFO` for live ones)
///   as a share of all cores. Process CPU, not system CPU, because the
///   question is whether the model runs on the CPU: a graph placed there
///   drives this figure towards 100 %, while Neural Engine or GPU execution
///   leaves it near idle.
/// - GPU is the accelerator driver's "Device Utilization %" from
///   `IOAccelerator`'s `PerformanceStatistics`, readable from user space on
///   Apple silicon without an entitlement (`ioreg -r -c IOAccelerator` shows
///   it). It is system-wide — there is no per-process GPU counter — and it
///   may be absent, in which case the reading is nil and the UI hides the
///   line rather than drawing zeros.
/// - There is no Neural Engine reading: macOS has no public ANE counter.
public final class SystemRuntimeTelemetryProvider: RuntimeTelemetryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var previousCPUSample: CPUSample?
    private let processorCount: Double

    public init(processorCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.processorCount = Double(max(processorCount, 1))
    }

    // MARK: Memory

    public func memoryFootprintBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    // MARK: CPU

    private struct CPUSample {
        let cpuSeconds: Double
        let wall: ContinuousClock.Instant
    }

    public func cpuUtilisation() -> Double? {
        guard let cpuSeconds = Self.processCPUSeconds() else { return nil }
        let sample = CPUSample(cpuSeconds: cpuSeconds, wall: ContinuousClock().now)
        lock.lock()
        let previous = previousCPUSample
        previousCPUSample = sample
        lock.unlock()
        guard let previous else { return nil }
        let wallSeconds = Self.seconds(sample.wall - previous.wall)
        guard wallSeconds > 0 else { return nil }
        let share = (sample.cpuSeconds - previous.cpuSeconds) / (wallSeconds * processorCount)
        return min(max(share, 0), 1)
    }

    /// User + system CPU time of the whole task: finished threads from the
    /// basic info, running threads from the thread-times info.
    private static func processCPUSeconds() -> Double? {
        var basic = mach_task_basic_info_data_t()
        var basicCount = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let basicResult = withUnsafeMutablePointer(to: &basic) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(basicCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &basicCount)
            }
        }
        guard basicResult == KERN_SUCCESS else { return nil }

        var threads = task_thread_times_info_data_t()
        var threadsCount = mach_msg_type_number_t(
            MemoryLayout<task_thread_times_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let threadsResult = withUnsafeMutablePointer(to: &threads) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(threadsCount)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), rebound, &threadsCount)
            }
        }
        guard threadsResult == KERN_SUCCESS else { return nil }

        return seconds(basic.user_time) + seconds(basic.system_time)
            + seconds(threads.user_time) + seconds(threads.system_time)
    }

    private static func seconds(_ value: time_value_t) -> Double {
        Double(value.seconds) + Double(value.microseconds) / 1_000_000
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    // MARK: GPU

    static let performanceStatisticsKey = "PerformanceStatistics"
    static let deviceUtilisationKey = "Device Utilization %"

    public func gpuUtilisation() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iterator
        ) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var reading: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            if reading == nil,
               let statistics = IORegistryEntryCreateCFProperty(
                   entry,
                   Self.performanceStatisticsKey as CFString,
                   kCFAllocatorDefault,
                   0
               )?.takeRetainedValue() as? [String: Any],
               let percent = statistics[Self.deviceUtilisationKey] as? NSNumber {
                reading = min(max(percent.doubleValue / 100, 0), 1)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return reading
    }
}
