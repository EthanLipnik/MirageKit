//
//  MirageRenderMemoryBudgetController.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Risk-aware render queue memory budgeting.
//

import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#endif

final class MirageRenderMemoryBudgetController: @unchecked Sendable {
    enum PressureLevel: Int {
        case normal
        case warning
        case critical
    }

    private let lock = NSLock()
    private let physicalMemoryBytes: UInt64
    private let sampleIntervalSeconds: CFAbsoluteTime = 0.25

    private var signalPressureLevel: PressureLevel = .normal
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private var lastFootprintSampleTime: CFAbsoluteTime = 0
    private var cachedFootprintBytes: UInt64 = 0

    init(physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory) {
        self.physicalMemoryBytes = physicalMemoryBytes
        startMemoryPressureMonitoring()
    }

    deinit {
        memoryPressureSource?.cancel()
    }

    func effectiveQueueBudgetBytes(normalBudgetBytes: Int) -> Int {
        let baseBudget = max(0, normalBudgetBytes)
        guard baseBudget > 0 else { return 0 }

        switch effectivePressureLevel() {
        case .normal:
            // Keep queue byte limiting disabled under normal conditions.
            return 0
        case .warning:
            return max(64 * 1024 * 1024, baseBudget)
        case .critical:
            return max(32 * 1024 * 1024, baseBudget / 2)
        }
    }

    // MARK: - Pressure Assessment

    private func effectivePressureLevel() -> PressureLevel {
        let sampledLevel = sampledFootprintPressureLevel()
        let signaledLevel: PressureLevel
        lock.lock()
        signaledLevel = signalPressureLevel
        lock.unlock()

        return sampledLevel.rawValue >= signaledLevel.rawValue ? sampledLevel : signaledLevel
    }

    private func sampledFootprintPressureLevel() -> PressureLevel {
        guard physicalMemoryBytes > 0,
              let footprintBytes = sampledFootprintBytes() else {
            return .normal
        }

        let footprintRatio = Double(footprintBytes) / Double(physicalMemoryBytes)

        #if os(iOS) || os(visionOS)
        if footprintRatio >= 0.12 {
            return .critical
        }
        if footprintRatio >= 0.08 {
            return .warning
        }
        #elseif os(macOS)
        if footprintRatio >= 0.25 {
            return .critical
        }
        if footprintRatio >= 0.15 {
            return .warning
        }
        #else
        if footprintRatio >= 0.18 {
            return .critical
        }
        if footprintRatio >= 0.12 {
            return .warning
        }
        #endif

        return .normal
    }

    // MARK: - Footprint Sampling

    private func sampledFootprintBytes() -> UInt64? {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let cachedAge = now - lastFootprintSampleTime
        if lastFootprintSampleTime > 0,
           cachedAge < sampleIntervalSeconds {
            let cached = cachedFootprintBytes
            lock.unlock()
            return cached > 0 ? cached : nil
        }
        lock.unlock()

        let sampled = currentPhysicalFootprintBytes() ?? 0

        lock.lock()
        cachedFootprintBytes = sampled
        lastFootprintSampleTime = now
        lock.unlock()

        return sampled > 0 ? sampled : nil
    }

    private func currentPhysicalFootprintBytes() -> UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }

        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
        #else
        return nil
        #endif
    }

    // MARK: - Memory Pressure Signals

    private func startMemoryPressureMonitoring() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.normal, .warning, .critical],
            queue: .global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            guard let self,
                  let events = self.memoryPressureSource?.data else {
                return
            }
            self.handleMemoryPressureEvent(events)
        }
        source.resume()
    }

    private func handleMemoryPressureEvent(_ events: DispatchSource.MemoryPressureEvent) {
        let level: PressureLevel
        if events.contains(.critical) {
            level = .critical
        } else if events.contains(.warning) {
            level = .warning
        } else {
            level = .normal
        }

        lock.lock()
        signalPressureLevel = level
        lock.unlock()
    }
}
