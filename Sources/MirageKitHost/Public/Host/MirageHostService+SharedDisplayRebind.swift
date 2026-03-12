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
    case skipResizeInFlight
    case rebind
}

func desktopGenerationChangeRebindDecision(
    previousGeneration: UInt64,
    newGeneration: UInt64,
    desktopResizeInFlight: Bool
)
-> DesktopGenerationChangeRebindDecision {
    guard previousGeneration != newGeneration else { return .skipNoChange }
    guard !desktopResizeInFlight else { return .skipResizeInFlight }
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
        guard let desktopStreamID, let desktopContext = desktopStreamContext else { return }

        desktopDisplayBounds = displayBounds
        sharedVirtualDisplayScaleFactor = max(1.0, newContext.scaleFactor)
        let rebindDecision = desktopGenerationChangeRebindDecision(
            previousGeneration: previousGeneration,
            newGeneration: newContext.generation,
            desktopResizeInFlight: desktopResizeInFlight
        )
        if rebindDecision == .skipResizeInFlight {
            MirageLogger
                .host(
                    "Skipping desktop generation-change rebind during in-flight resize (\(previousGeneration) -> \(newContext.generation))"
                )
            return
        }
        guard rebindDecision == .rebind else { return }

        do {
            if desktopStreamMode == .mirrored {
                await setupDisplayMirroring(targetDisplayID: newContext.displayID)
            } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: newContext.displayID)
            }

            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
            try await desktopContext.updateCaptureDisplay(
                captureDisplay,
                resolution: newContext.resolution
            )

            let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
            let inputBounds = resolvedDesktopInputBounds(
                physicalBounds: primaryBounds,
                virtualResolution: newContext.resolution
            )
            inputStreamCacheActor.updateWindowFrame(desktopStreamID, newFrame: inputBounds)
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
