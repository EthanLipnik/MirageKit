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

#if os(macOS)
import ScreenCaptureKit

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
            knownResolution: newContext.resolution
        )
        sharedVirtualDisplayBounds = displayBounds
        sharedVirtualDisplayGeneration = newContext.generation
        MirageLogger
            .host(
                "Shared display generation change: \(previousGeneration) -> \(newContext.generation) (display \(newContext.displayID))"
            )

        var streamIDsToRebind: [StreamID] = []
        for session in activeStreams {
            guard let context = streamsByID[session.id] else { continue }
            guard await context.isUsingVirtualDisplay() else { continue }
            guard await context.isReadyForSharedDisplayRebind() else { continue }
            let contextGeneration = await context.getSharedDisplayGeneration()
            guard contextGeneration != newContext.generation else { continue }
            streamIDsToRebind.append(session.id)
        }

        for streamID in streamIDsToRebind {
            guard let context = streamsByID[streamID] else { continue }
            do {
                try await context.rebindToSharedDisplay(
                    newContext: newContext,
                    reason: "shared display generation change"
                )

                if let index = activeStreams.firstIndex(where: { $0.id == streamID }) {
                    let session = activeStreams[index]
                    let updatedFrame = CGRect(origin: displayBounds.origin, size: session.window.frame.size)
                    let updatedWindow = MirageWindow(
                        id: session.window.id,
                        title: session.window.title,
                        application: session.window.application,
                        frame: updatedFrame,
                        isOnScreen: session.window.isOnScreen,
                        windowLayer: session.window.windowLayer
                    )
                    activeStreams[index] = MirageStreamSession(
                        id: session.id,
                        window: updatedWindow,
                        client: session.client
                    )
                    inputStreamCacheActor.updateWindowFrame(streamID, newFrame: updatedFrame)
                }

                await sendStreamScaleUpdate(streamID: streamID)
            } catch {
                MirageLogger.error(
                    .host,
                    "Failed to rebind stream \(streamID) after shared display generation change: \(error)"
                )
            }
        }

        await handleDesktopStreamSharedDisplayGenerationChange(newContext: newContext, displayBounds: displayBounds)
    }

    private func handleDesktopStreamSharedDisplayGenerationChange(
        newContext: SharedVirtualDisplayManager.DisplaySnapshot,
        displayBounds: CGRect
    )
    async {
        guard desktopUsesVirtualDisplay else { return }
        guard let desktopStreamID, let desktopContext = desktopStreamContext else { return }

        desktopDisplayBounds = displayBounds

        do {
            if desktopStreamMode == .mirrored {
                await setupDisplayMirroring(targetDisplayID: newContext.displayID)
            } else if !mirroredPhysicalDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
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
