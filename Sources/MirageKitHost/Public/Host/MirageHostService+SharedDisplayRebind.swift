//
//  MirageHostService+SharedDisplayRebind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Shared virtual display generation rebind handling.
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
@MainActor
extension MirageHostService {
    /// Rebinds host stream state after the shared virtual display is recreated.
    func handleSharedDisplayGenerationChange(
        newContext: MirageHostVirtualDisplaySnapshot,
        previousGeneration: UInt64
    )
    async {
        guard previousGeneration != newContext.generation else { return }

        clearCurrentDesktopGeometryContract()

        let displayBounds = platformVirtualDisplayBackend.displayBounds(
            newContext.displayID,
            knownResolution: SharedVirtualDisplayManager.logicalResolution(
                for: newContext.resolution,
                scaleFactor: newContext.scaleFactor
            )
        )
        sharedVirtualDisplayGeneration = newContext.generation
        sharedVirtualDisplayScaleFactor = max(1.0, newContext.scaleFactor)
        MirageLogger
            .host(
                "Shared display generation change: \(previousGeneration) -> \(newContext.generation) (display \(newContext.displayID))"
            )

        await handleDesktopStreamSharedDisplayGenerationChange(
            newContext: newContext,
            previousGeneration: previousGeneration,
            displayBounds: displayBounds
        )
    }

    /// Retargets the desktop stream to the new shared-display generation.
    private func handleDesktopStreamSharedDisplayGenerationChange(
        newContext: MirageHostVirtualDisplaySnapshot,
        previousGeneration: UInt64,
        displayBounds: CGRect
    )
    async {
        var virtualDisplaySetupGuardToken: UUID?
        defer {
            if let token = virtualDisplaySetupGuardToken {
                Task { @MainActor [weak self] in
                    await self?.cancelVirtualDisplaySetupGuard(
                        token,
                        reason: "shared_display_generation_change_aborted"
                    )
                }
            }
        }

        guard let desktopStreamID, let desktopContext = desktopStreamContext else { return }

        desktopVirtualDisplayID = newContext.displayID
        desktopCaptureSource = .virtualDisplay
        desktopDisplayBounds = displayBounds
        sharedVirtualDisplayScaleFactor = max(1.0, newContext.scaleFactor)
        if desktopSharedDisplayTransitionInFlight {
            MirageLogger
                .host(
                    "Skipping desktop generation-change rebind during desktop shared-display transition (\(previousGeneration) -> \(newContext.generation))"
                )
            return
        }

        do {
            virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
                reason: "shared_display_generation_change"
            )
            if desktopStreamMode == .unified {
                _ = await setupDisplayMirroring(
                    targetDisplayID: newContext.displayID,
                    expectedPixelResolution: newContext.resolution
                )
            } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                _ = await disableDisplayMirroring(displayID: newContext.displayID)
            }

            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6)
            try await desktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: newContext.resolution
            )
            MirageLogger.host(
                "Desktop shared display rebind advanced stream epoch and requested recovery keyframe"
            )
            await refreshLightsOutCaptureExclusions()

            let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
            let inputGeometry = updateDesktopInputGeometry(
                streamID: desktopStreamID,
                physicalBounds: primaryBounds,
                virtualResolution: newContext.resolution
            )
            if let token = virtualDisplaySetupGuardToken {
                await completeVirtualDisplaySetupGuard(
                    token,
                    reason: "shared_display_generation_change"
                )
                virtualDisplaySetupGuardToken = nil
            }
            await sendStreamScaleUpdate(streamID: desktopStreamID)
            MirageLogger
                .host(
                    "Desktop stream rebound to shared display generation \(newContext.generation) " +
                        "(Virtual Display, input bounds: \(inputGeometry.inputBounds))"
                )
        } catch {
            MirageLogger.error(
                .host,
                "Failed to update desktop stream after shared display generation change: \(error)"
            )
        }
    }
}

#endif
