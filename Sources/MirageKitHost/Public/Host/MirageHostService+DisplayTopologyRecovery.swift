//
//  MirageHostService+DisplayTopologyRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Restarts desktop virtual-display capture after a topology change invalidates geometry.
    func restartDesktopVirtualDisplayAfterTopologyChange(
        streamID: StreamID,
        virtualResolution requestedVirtualResolution: CGSize?,
        reason: String
    )
    async {
        desktopDisplayTopologyRefreshTask = nil
        guard streamID == desktopStreamID,
              !desktopUsesHostResolution,
              activeDesktopResizeRequest == nil,
              !desktopSharedDisplayTransitionInFlight,
              let desktopContext = desktopStreamContext,
              let desktopSessionID,
              let clientContext = desktopStreamClientContext else {
            return
        }

        let fallbackResolution = requestedVirtualResolution ?? desktopMirroredVirtualResolution
        guard let virtualResolution = await currentDesktopVirtualDisplayPixelResolution(
            fallback: fallbackResolution
        ) else {
            await sendStreamScaleUpdate(streamID: streamID)
            return
        }

        let transitionID = UUID()
        beginDesktopSharedDisplayTransition()
        defer { endDesktopSharedDisplayTransition() }

        await desktopContext.suspendEncodingForDesktopResize()

        do {
            var displaySnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
            if let displayID = desktopVirtualDisplayID,
               let observedSnapshot = await SharedVirtualDisplayManager.shared.updateSharedDisplayObservedResolution(
                   displayID: displayID,
                   resolution: virtualResolution
               ) {
                displaySnapshot = observedSnapshot
            }

            if let displaySnapshot {
                desktopVirtualDisplayID = displaySnapshot.displayID
                sharedVirtualDisplayGeneration = displaySnapshot.generation
                sharedVirtualDisplayScaleFactor = max(1.0, displaySnapshot.scaleFactor)
                desktopDisplayBounds = CGVirtualDisplayBridge.displayBounds(
                    displaySnapshot.displayID,
                    knownResolution: SharedVirtualDisplayManager.logicalResolution(
                        for: displaySnapshot.resolution,
                        scaleFactor: max(1.0, displaySnapshot.scaleFactor)
                    )
                )
            } else {
                desktopDisplayBounds = resolveDesktopDisplayBounds()
            }

            if desktopStreamMode == .unified {
                let targetDisplayID = desktopVirtualDisplayID ?? displaySnapshot?.displayID
                if let targetDisplayID {
                    _ = await setupDisplayMirroring(
                        targetDisplayID: targetDisplayID,
                        expectedPixelResolution: displaySnapshot?.resolution ?? virtualResolution
                    )
                }
            } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                _ = await disableDisplayMirroring(displayID: desktopVirtualDisplayID ?? CGMainDisplayID())
            }

            await desktopContext.updateVirtualDisplaySnapshotResolution(virtualResolution)
            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 8)
            guard isDesktopDisplayTopologyRefreshStillActive(
                streamID: streamID,
                clientSessionID: clientContext.sessionID
            ) else {
                await desktopContext.resumeEncodingAfterDesktopResize()
                MirageLogger.host(
                    "Desktop display topology refresh ended because the stream is no longer active"
                )
                return
            }
            try await desktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: virtualResolution
            )
            guard isDesktopDisplayTopologyRefreshStillActive(
                streamID: streamID,
                clientSessionID: clientContext.sessionID
            ) else {
                await desktopContext.resumeEncodingAfterDesktopResize()
                MirageLogger.host(
                    "Desktop display topology refresh completed after the stream stopped"
                )
                return
            }

            let inputGeometry = updateDesktopInputGeometry(
                streamID: streamID,
                physicalBounds: refreshDesktopPrimaryPhysicalBounds(),
                virtualResolution: virtualResolution
            )

            let streamStart = await desktopContext.streamStartSnapshot
            let displayResolution = await currentDesktopStartedResolution(
                fallback: CGSize(
                    width: streamStart.encodedDimensions.width,
                    height: streamStart.encodedDimensions.height
                )
            )
            desktopPresentationGeneration &+= 1
            let message = DesktopStreamStartedMessage(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                width: Int(displayResolution.width),
                height: Int(displayResolution.height),
                frameRate: streamStart.targetFrameRate,
                codec: streamStart.codec,
                displayCount: 1,
                dimensionToken: streamStart.dimensionToken,
                acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
                transitionID: transitionID,
                transitionPhase: .resize,
                transitionOutcome: .resized,
                desktopPresentationGeneration: desktopPresentationGeneration,
                captureSource: desktopCaptureSource,
                allowsClientResize: desktopCaptureSource != .mainDisplayFallback,
                presentationWidth: Int(displayResolution.width.rounded()),
                presentationHeight: Int(displayResolution.height.rounded())
            )

            if !clientContext.sendBestEffort(.desktopStreamStarted, content: message) {
                MirageLogger.error(.host, "Failed to encode desktop topology refresh for stream \(streamID)")
            }
            await desktopContext.resumeEncodingAfterDesktopResize()
            MirageLogger.host(
                "Desktop display topology refresh restarted virtual display setup " +
                    "(reason=\(reason), transition=\(transitionID.uuidString), input bounds: \(inputGeometry.inputBounds))"
            )
        } catch {
            await desktopContext.resumeEncodingAfterDesktopResize()
            guard isDesktopDisplayTopologyRefreshStillActive(
                streamID: streamID,
                clientSessionID: clientContext.sessionID
            ) else {
                MirageLogger.host(
                    "Desktop display topology refresh stopped during teardown after \(reason): \(error)"
                )
                return
            }
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to restart desktop virtual display after display topology change: "
            )
        }
    }

    /// Returns whether the queued topology refresh still targets the active desktop stream.
    func isDesktopDisplayTopologyRefreshStillActive(
        streamID: StreamID,
        clientSessionID: UUID
    ) -> Bool {
        streamID == desktopStreamID &&
            desktopStreamContext != nil &&
            desktopStreamClientContext?.sessionID == clientSessionID
    }

    /// Resets capture when the virtual-display mode changes outside Mirage's resize flow.
    func resetDesktopCaptureForUnmanagedResolutionChangeIfNeeded(
        streamID: StreamID,
        virtualResolution: CGSize
    )
    async -> Bool {
        guard streamID == desktopStreamID,
              !desktopUsesHostResolution,
              activeDesktopResizeRequest == nil,
              !desktopSharedDisplayTransitionInFlight,
              let desktopContext = desktopStreamContext,
              let displayID = desktopVirtualDisplayID else {
            return false
        }

        do {
            if let snapshot = await SharedVirtualDisplayManager.shared.updateSharedDisplayObservedResolution(
                displayID: displayID,
                resolution: virtualResolution
            ) {
                sharedVirtualDisplayGeneration = snapshot.generation
                sharedVirtualDisplayScaleFactor = max(1.0, snapshot.scaleFactor)
            }
            await desktopContext.updateVirtualDisplaySnapshotResolution(virtualResolution)
            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6)
            try await desktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: virtualResolution
            )
            refreshDesktopInputGeometry(
                streamID: streamID,
                physicalBounds: refreshDesktopPrimaryPhysicalBounds(),
                virtualResolution: virtualResolution
            )
            await sendStreamScaleUpdate(streamID: streamID)
            MirageLogger.host(
                "Desktop display mode changed outside Mirage resize; reset capture to " +
                    "\(Int(virtualResolution.width))x\(Int(virtualResolution.height)) px"
            )
            return true
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to reset desktop capture after unmanaged display mode change: "
            )
            return false
        }
    }
}
#endif
