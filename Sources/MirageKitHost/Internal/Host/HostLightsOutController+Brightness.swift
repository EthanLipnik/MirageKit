//
//  HostLightsOutController+Brightness.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Display gamma capture and dimming support for host Lights Out mode.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics

#if os(macOS)
extension HostLightsOutController {
    // MARK: - Brightness

    func updateBrightnessSnapshot(for displayIDs: Set<CGDirectDisplayID>) {
        let removed = brightnessSnapshot.keys.filter { !displayIDs.contains($0) }
        for displayID in removed {
            if let snapshot = brightnessSnapshot[displayID] {
                applyGamma(snapshot, scale: 1.0, displayID: displayID)
            }
            brightnessSnapshot.removeValue(forKey: displayID)
        }

        for displayID in displayIDs where brightnessSnapshot[displayID] == nil {
            if let snapshot = captureGammaSnapshot(for: displayID) {
                brightnessSnapshot[displayID] = snapshot
            }
        }
    }

    func dimDisplays() {
        for (displayID, snapshot) in brightnessSnapshot {
            applyGamma(snapshot, scale: Self.dimmedGammaScale, displayID: displayID)
        }
    }

    func restoreBrightness() {
        for (displayID, snapshot) in brightnessSnapshot {
            applyGamma(snapshot, scale: 1.0, displayID: displayID)
        }
    }

    func applyRevealState() {
        if let revealUntil, revealClock.now < revealUntil {
            showMessage()
            restoreBrightness()
        } else {
            hideMessage()
            dimDisplays()
        }
    }

    private func captureGammaSnapshot(for displayID: CGDirectDisplayID) -> HostLightsOutGammaSnapshot? {
        let maxSamples = 256
        var red = [CGGammaValue](repeating: 0, count: maxSamples)
        var green = [CGGammaValue](repeating: 0, count: maxSamples)
        var blue = [CGGammaValue](repeating: 0, count: maxSamples)
        var sampleCount: UInt32 = 0
        let result = CGGetDisplayTransferByTable(
            displayID,
            UInt32(maxSamples),
            &red,
            &green,
            &blue,
            &sampleCount
        )
        guard result == .success, sampleCount > 0 else { return nil }
        let count = Int(sampleCount)
        return HostLightsOutGammaSnapshot(
            red: Array(red.prefix(count)),
            green: Array(green.prefix(count)),
            blue: Array(blue.prefix(count)),
            sampleCount: sampleCount
        )
    }

    private func applyGamma(_ snapshot: HostLightsOutGammaSnapshot, scale: CGGammaValue, displayID: CGDirectDisplayID) {
        let clampedScale = max(0, min(1, scale))
        let red = snapshot.red.map { min(1, max(0, $0 * clampedScale)) }
        let green = snapshot.green.map { min(1, max(0, $0 * clampedScale)) }
        let blue = snapshot.blue.map { min(1, max(0, $0 * clampedScale)) }

        red.withUnsafeBufferPointer { redPtr in
            green.withUnsafeBufferPointer { greenPtr in
                blue.withUnsafeBufferPointer { bluePtr in
                    guard let redBase = redPtr.baseAddress,
                          let greenBase = greenPtr.baseAddress,
                          let blueBase = bluePtr.baseAddress else {
                        return
                    }
                    let result = CGSetDisplayTransferByTable(
                        displayID,
                        snapshot.sampleCount,
                        redBase,
                        greenBase,
                        blueBase
                    )
                    if result != .success {
                        MirageLogger.host("Lights Out: failed to apply display gamma (\(displayID), error \(result.rawValue))")
                    }
                }
            }
        }
    }
}
#endif
