//
//  MirageHostService+DisplayMirroringStability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

#if os(macOS)

extension MirageHostService {
    func waitForDisplayMirroringTargetStability(
        targetDisplayID: CGDirectDisplayID,
        expectedPixelResolution: CGSize?,
        requiresResidualMirageDisplaysClear: Bool = true,
        stableSampleCount: Int = 2,
        maxWaitMs: Int = 2500,
        pollIntervalMs: Int = 120
    )
    async -> Bool {
        let deadline = Date().addingTimeInterval(Double(maxWaitMs) / 1000.0)
        var consecutiveStableSamples = 0
        var lastDecision: DisplayMirroringTargetStabilityDecision = .waitForTargetOnline

        while true {
            let onlineDisplayIDs = currentOnlineDisplayIDsForMirroringStability()
            let observedResolution = displayMirroringObservedTargetPixelResolution(
                modePixelResolution: platformVirtualDisplayBackend.currentDisplayModeSizes(targetDisplayID)?.pixel,
                displayPixelDimensions: CGSize(
                    width: CGFloat(CGDisplayPixelsWide(targetDisplayID)),
                    height: CGFloat(CGDisplayPixelsHigh(targetDisplayID))
                ),
                displayBoundsSize: CGDisplayBounds(targetDisplayID).size
            )
            let decision = displayMirroringTargetStabilityDecision(
                targetDisplayID: targetDisplayID,
                onlineDisplayIDs: onlineDisplayIDs,
                observedTargetPixelResolution: observedResolution,
                expectedTargetPixelResolution: expectedPixelResolution,
                requiresResidualMirageDisplaysClear: requiresResidualMirageDisplaysClear,
                isMirageDisplay: { platformVirtualDisplayBackend.isMirageDisplay($0) }
            )
            lastDecision = decision

            if decision == .stable {
                consecutiveStableSamples += 1
                if consecutiveStableSamples >= stableSampleCount { return true }
            } else {
                consecutiveStableSamples = 0
            }

            guard Date() < deadline else {
                MirageLogger.host(
                    "Display mirroring target stability timed out for \(targetDisplayID): " +
                        displayMirroringTargetStabilityDescription(lastDecision)
                )
                return false
            }

            do {
                try await Task.sleep(for: .milliseconds(pollIntervalMs))
            } catch {
                return false
            }
        }
    }

    func currentOnlineDisplayIDsForMirroringStability() -> [CGDirectDisplayID] {
        platformVirtualDisplayBackend.onlineDisplayIDs()
    }

    func displayMirroringTargetStabilityDescription(
        _ decision: DisplayMirroringTargetStabilityDecision
    )
    -> String {
        switch decision {
        case .stable:
            return "stable"
        case .waitForTargetOnline:
            return "target display not online"
        case let .waitForExpectedMode(observed, expected):
            let expectedText = "\(Int(expected.width))x\(Int(expected.height))"
            guard let observed else { return "target mode unavailable, expected \(expectedText)" }
            return "target mode \(Int(observed.width))x\(Int(observed.height)) != expected \(expectedText)"
        case let .waitForResidualMirageDisplays(displayIDs):
            return "residual Mirage displays still online: \(displayIDs)"
        }
    }
}

#endif
