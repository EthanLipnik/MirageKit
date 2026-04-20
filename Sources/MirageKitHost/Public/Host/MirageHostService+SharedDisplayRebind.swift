//
//  MirageHostService+SharedDisplayRebind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/27/26.
//
//  Shared virtual display generation rebind handling.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

enum DesktopGenerationChangeRebindDecision: Equatable {
    case skipNoChange
    case skipSharedDisplayTransitionInFlight
    case rebind
}

func desktopGenerationChangeRebindDecision(
    previousGeneration: UInt64,
    newGeneration: UInt64,
    sharedDisplayTransitionInFlight: Bool
)
-> DesktopGenerationChangeRebindDecision {
    guard previousGeneration != newGeneration else { return .skipNoChange }
    guard !sharedDisplayTransitionInFlight else { return .skipSharedDisplayTransitionInFlight }
    return .rebind
}

@MainActor
extension MirageHostService {
    func handleSharedDisplayGenerationChange(
        newContext: SharedVirtualDisplayManager.DisplaySnapshot,
        previousGeneration: UInt64
    )
    async {
        guard previousGeneration != newContext.generation else { return }

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
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

    private func handleDesktopStreamSharedDisplayGenerationChange(
        newContext: SharedVirtualDisplayManager.DisplaySnapshot,
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

        desktopDisplayBounds = displayBounds
        sharedVirtualDisplayScaleFactor = max(1.0, newContext.scaleFactor)
        let rebindDecision = desktopGenerationChangeRebindDecision(
            previousGeneration: previousGeneration,
            newGeneration: newContext.generation,
            sharedDisplayTransitionInFlight: desktopSharedDisplayTransitionInFlight
        )
        if rebindDecision == .skipSharedDisplayTransitionInFlight {
            MirageLogger
                .host(
                    "Skipping desktop generation-change rebind during desktop shared-display transition (\(previousGeneration) -> \(newContext.generation))"
                )
            return
        }
        guard rebindDecision == .rebind else { return }

        do {
            virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
                reason: "shared_display_generation_change"
            )
            if desktopStreamMode == .unified {
                await setupDisplayMirroring(
                    targetDisplayID: newContext.displayID,
                    expectedPixelResolution: newContext.resolution
                )
            } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: newContext.displayID)
            }

            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
            try await desktopContext.updateCaptureDisplay(
                captureDisplay,
                resolution: newContext.resolution
            )

            let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
            desktopMirroredVirtualResolution = newContext.resolution
            let inputBounds = resolvedDesktopInputBounds(
                physicalBounds: primaryBounds,
                virtualResolution: newContext.resolution
            )
            inputStreamCacheActor.updateWindowFrame(desktopStreamID, newFrame: inputBounds)
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
                    "Desktop stream rebound to shared display generation \(newContext.generation) (Virtual Display)"
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
