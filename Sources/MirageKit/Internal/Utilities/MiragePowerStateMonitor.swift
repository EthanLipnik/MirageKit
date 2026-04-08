//
//  MiragePowerStateMonitor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/5/26.
//

import Foundation

#if os(macOS)
import IOKit.ps
#elseif canImport(UIKit)
import UIKit
#endif

package struct MiragePowerStateSnapshot: Sendable, Equatable {
    package var isSystemLowPowerModeEnabled: Bool
    package var isOnBattery: Bool?

    package init(
        isSystemLowPowerModeEnabled: Bool,
        isOnBattery: Bool?
    ) {
        self.isSystemLowPowerModeEnabled = isSystemLowPowerModeEnabled
        self.isOnBattery = isOnBattery
    }

    package var supportsBatteryState: Bool {
        isOnBattery != nil
    }
}

@MainActor
package final class MiragePowerStateMonitor {
    package typealias UpdateHandler = @MainActor @Sendable (MiragePowerStateSnapshot) -> Void

    private var updateHandler: UpdateHandler?
    private var lowPowerObserver: NSObjectProtocol?
    private var isMonitoring = false

    #if os(macOS)
    private var powerSourceRunLoopSource: CFRunLoopSource?
    private var cachedMacBatteryState: Bool?
    private var hasCachedMacBatteryState = false
    #elseif canImport(UIKit)
    private var batteryStateObserver: NSObjectProtocol?
    private var batteryLevelObserver: NSObjectProtocol?
    private var previousBatteryMonitoringEnabled: Bool?
    #endif

    package init() {}

    package func start(onUpdate: @escaping UpdateHandler) {
        updateHandler = onUpdate
        if !isMonitoring {
            isMonitoring = true
            registerLowPowerModeObserver()
            registerPlatformPowerObservers()
        }
        Task { @MainActor [weak self] in
            await self?.dispatchCurrentSnapshot()
        }
    }

    package func stop() {
        isMonitoring = false
        updateHandler = nil
        unregisterLowPowerModeObserver()
        unregisterPlatformPowerObservers()
    }

    package func currentSnapshot() async -> MiragePowerStateSnapshot {
        MiragePowerStateSnapshot(
            isSystemLowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            isOnBattery: await currentBatteryState()
        )
    }

    private func dispatchCurrentSnapshot() async {
        updateHandler?(await currentSnapshot())
    }

    private func registerLowPowerModeObserver() {
        guard lowPowerObserver == nil else { return }
        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.dispatchCurrentSnapshot()
            }
        }
    }

    private func unregisterLowPowerModeObserver() {
        guard let lowPowerObserver else { return }
        NotificationCenter.default.removeObserver(lowPowerObserver)
        self.lowPowerObserver = nil
    }

    private func registerPlatformPowerObservers() {
        #if os(macOS)
        registerPowerSourceObserver()
        #elseif canImport(UIKit)
        registerBatteryObservers()
        #endif
    }

    private func unregisterPlatformPowerObservers() {
        #if os(macOS)
        unregisterPowerSourceObserver()
        #elseif canImport(UIKit)
        unregisterBatteryObservers()
        #endif
    }

    private func currentBatteryState() async -> Bool? {
        #if os(macOS)
        if !isMonitoring || !hasCachedMacBatteryState {
            cachedMacBatteryState = await Self.readMacBatteryState()
            hasCachedMacBatteryState = true
        }
        return cachedMacBatteryState
        #elseif canImport(UIKit)
        readDeviceBatteryState()
        #else
        nil
        #endif
    }
}

#if os(macOS)
private func miragePowerSourceDidChange(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let monitor = Unmanaged<MiragePowerStateMonitor>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor in
        await monitor.handlePowerSourceDidChange()
    }
}

@MainActor
private extension MiragePowerStateMonitor {
    func registerPowerSourceObserver() {
        guard powerSourceRunLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            miragePowerSourceDidChange,
            context
        )?.takeRetainedValue() else {
            return
        }
        powerSourceRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    func unregisterPowerSourceObserver() {
        guard let source = powerSourceRunLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        powerSourceRunLoopSource = nil
        hasCachedMacBatteryState = false
        cachedMacBatteryState = nil
    }

    func handlePowerSourceDidChange() async {
        cachedMacBatteryState = await Self.readMacBatteryState()
        hasCachedMacBatteryState = true
        await dispatchCurrentSnapshot()
    }

    nonisolated static func readMacBatteryState() async -> Bool? {
        await Task.detached(priority: .utility) {
            let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
            let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
            guard !sources.isEmpty else { return nil }

            var sawAC = false
            var sawBattery = false

            for source in sources {
                guard let descriptionRef = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue(),
                      let description = descriptionRef as? [String: Any],
                      let state = description[kIOPSPowerSourceStateKey as String] as? String else {
                    continue
                }

                if state == kIOPSBatteryPowerValue {
                    sawBattery = true
                } else if state == kIOPSACPowerValue {
                    sawAC = true
                }
            }

            if sawBattery { return true }
            if sawAC { return false }
            return nil
        }
        .value
    }
}
#elseif canImport(UIKit)
@MainActor
private extension MiragePowerStateMonitor {
    func registerBatteryObservers() {
        guard batteryStateObserver == nil, batteryLevelObserver == nil else { return }

        let device = UIDevice.current
        previousBatteryMonitoringEnabled = device.isBatteryMonitoringEnabled
        if !device.isBatteryMonitoringEnabled {
            device.isBatteryMonitoringEnabled = true
        }

        batteryStateObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.dispatchCurrentSnapshot()
            }
        }

        batteryLevelObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.batteryLevelDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.dispatchCurrentSnapshot()
            }
        }
    }

    func unregisterBatteryObservers() {
        if let batteryStateObserver {
            NotificationCenter.default.removeObserver(batteryStateObserver)
            self.batteryStateObserver = nil
        }
        if let batteryLevelObserver {
            NotificationCenter.default.removeObserver(batteryLevelObserver)
            self.batteryLevelObserver = nil
        }

        if let previous = previousBatteryMonitoringEnabled {
            UIDevice.current.isBatteryMonitoringEnabled = previous
            previousBatteryMonitoringEnabled = nil
        }
    }

    func readDeviceBatteryState() -> Bool? {
        switch UIDevice.current.batteryState {
        case .unknown:
            return nil
        case .unplugged:
            return true
        case .charging, .full:
            return false
        @unknown default:
            return nil
        }
    }
}
#endif
