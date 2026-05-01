//
//  MirageHostService+DisplayTopology.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit

func resolvedDesktopDisplayBounds(
    cachedBounds: CGRect?,
    liveBounds: CGRect?,
    displayModeSize: CGSize?,
    displayOrigin: CGPoint
)
-> CGRect? {
    if let liveBounds, liveBounds.width > 0, liveBounds.height > 0 {
        return liveBounds
    }

    if let displayModeSize,
       displayModeSize.width > 0,
       displayModeSize.height > 0 {
        return CGRect(origin: displayOrigin, size: displayModeSize)
    }

    if let cachedBounds, cachedBounds.width > 0, cachedBounds.height > 0 {
        return cachedBounds
    }

    return nil
}

func validDesktopVirtualResolution(_ resolution: CGSize?) -> CGSize? {
    guard let resolution,
          resolution.width > 0,
          resolution.height > 0 else {
        return nil
    }
    return resolution
}

func resolvedDesktopVirtualDisplayResolution(
    livePixelResolution: CGSize?,
    sharedSnapshotResolution: CGSize?,
    streamSnapshotResolution: CGSize?,
    cachedResolution: CGSize?,
    fallbackResolution: CGSize? = nil
)
-> CGSize? {
    validDesktopVirtualResolution(livePixelResolution) ??
        validDesktopVirtualResolution(sharedSnapshotResolution) ??
        validDesktopVirtualResolution(streamSnapshotResolution) ??
        validDesktopVirtualResolution(cachedResolution) ??
        validDesktopVirtualResolution(fallbackResolution)
}

func desktopVirtualResolutionChanged(
    from previousResolution: CGSize?,
    to nextResolution: CGSize?,
    tolerance: CGFloat = 1
)
-> Bool {
    guard let previousResolution = validDesktopVirtualResolution(previousResolution),
          let nextResolution = validDesktopVirtualResolution(nextResolution) else {
        return validDesktopVirtualResolution(previousResolution) != validDesktopVirtualResolution(nextResolution)
    }

    return abs(previousResolution.width - nextResolution.width) > tolerance ||
        abs(previousResolution.height - nextResolution.height) > tolerance
}

struct DesktopInputGeometryRefreshResult: Equatable {
    let physicalBounds: CGRect
    let virtualResolution: CGSize?
    let inputBounds: CGRect
}

@MainActor
extension MirageHostService {
    func ensureScreenParametersObserver() {
        guard screenParametersObserver == nil else { return }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleScreenParametersChange()
            }
        }
    }

    func removeScreenParametersObserver() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
        screenParametersObserver = nil
    }

    func handleScreenParametersChange() async {
        guard let desktopStreamID else { return }

        let previousDisplayBounds = desktopDisplayBounds
        let previousPrimaryPhysicalBounds = desktopPrimaryPhysicalBounds
        let previousPhysicalTopologySignature = desktopPhysicalDisplayTopologySignature
        let previousVirtualResolution = desktopMirroredVirtualResolution
        let refreshedDisplayBounds = resolveDesktopDisplayBounds()
        let refreshedPhysicalBounds = refreshDesktopPrimaryPhysicalBounds()
        let refreshedPhysicalTopologySignature = currentPhysicalDisplayTopologySignature()
        desktopPhysicalDisplayTopologySignature = refreshedPhysicalTopologySignature
        let virtualResolution = await currentDesktopVirtualDisplayPixelResolution(
            fallback: previousVirtualResolution
        )
        let geometry = updateDesktopInputGeometry(
            streamID: desktopStreamID,
            physicalBounds: refreshedPhysicalBounds,
            virtualResolution: virtualResolution
        )

        let displayBoundsChanged = refreshedDisplayBounds != previousDisplayBounds
        let physicalBoundsChanged = refreshedPhysicalBounds != previousPrimaryPhysicalBounds
        let virtualResolutionChanged = desktopVirtualResolutionChanged(
            from: previousVirtualResolution,
            to: geometry.virtualResolution
        )
        let physicalTopologyChanged =
            previousPhysicalTopologySignature != nil &&
            refreshedPhysicalTopologySignature != previousPhysicalTopologySignature
        guard displayBoundsChanged || physicalBoundsChanged || physicalTopologyChanged || virtualResolutionChanged else {
            return
        }
        let displaySizeChanged = refreshedDisplayBounds?.size != previousDisplayBounds?.size
        let physicalSizeChanged = refreshedPhysicalBounds.size != previousPrimaryPhysicalBounds?.size

        MirageLogger.host(
            "Desktop display topology changed; refreshed input bounds to \(geometry.inputBounds) " +
                "(physicalTopologyChanged=\(physicalTopologyChanged))"
        )

        let requiresVirtualDisplayRestart =
            !desktopUsesHostResolution &&
            (displaySizeChanged || physicalSizeChanged || physicalTopologyChanged || virtualResolutionChanged)

        if requiresVirtualDisplayRestart {
            scheduleDesktopDisplayTopologyRefresh(
                streamID: desktopStreamID,
                virtualResolution: geometry.virtualResolution,
                reason: "screen_parameters_changed"
            )
            return
        }

        if virtualResolutionChanged,
           let virtualResolution = geometry.virtualResolution,
           await resetDesktopCaptureForUnmanagedResolutionChangeIfNeeded(
               streamID: desktopStreamID,
               virtualResolution: virtualResolution
           ) {
            return
        }

        if displaySizeChanged || physicalSizeChanged || virtualResolutionChanged {
            await sendStreamScaleUpdate(streamID: desktopStreamID)
        }
    }

    func currentPhysicalDisplayTopologySignature() -> String? {
        var displayCount: UInt32 = 0
        let countResult = CGGetActiveDisplayList(0, nil, &displayCount)
        guard countResult == .success, displayCount > 0 else { return nil }

        var displayIDs = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        let listResult = CGGetActiveDisplayList(displayCount, &displayIDs, &displayCount)
        guard listResult == .success else { return nil }

        let entries = displayIDs
            .prefix(Int(displayCount))
            .filter { !CGVirtualDisplayBridge.isMirageDisplay($0) }
            .sorted()
            .map { displayID in
                let bounds = CGDisplayBounds(displayID)
                let mode = CGDisplayCopyDisplayMode(displayID)
                let pixelWidth = mode?.pixelWidth ?? 0
                let pixelHeight = mode?.pixelHeight ?? 0
                let refreshRate = mode.map { Int($0.refreshRate.rounded()) } ?? 0
                let isMain = displayID == CGMainDisplayID() ? 1 : 0
                return [
                    String(displayID),
                    String(isMain),
                    String(Int(bounds.origin.x.rounded())),
                    String(Int(bounds.origin.y.rounded())),
                    String(Int(bounds.width.rounded())),
                    String(Int(bounds.height.rounded())),
                    String(pixelWidth),
                    String(pixelHeight),
                    String(refreshRate)
                ].joined(separator: ":")
            }

        return entries.isEmpty ? nil : entries.joined(separator: "|")
    }

    func scheduleDesktopDisplayTopologyRefresh(
        streamID: StreamID,
        virtualResolution: CGSize?,
        reason: String
    ) {
        desktopDisplayTopologyRefreshTask?.cancel()
        desktopDisplayTopologyRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }

            guard let self else { return }
            await self.restartDesktopVirtualDisplayAfterTopologyChange(
                streamID: streamID,
                virtualResolution: virtualResolution,
                reason: reason
            )
        }
    }

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
            var displaySnapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot()
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
                desktopDisplayBounds = CGVirtualDisplayBridge.getDisplayBounds(
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
                    await setupDisplayMirroring(
                        targetDisplayID: targetDisplayID,
                        expectedPixelResolution: displaySnapshot?.resolution ?? virtualResolution
                    )
                }
            } else if !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty {
                await disableDisplayMirroring(displayID: desktopVirtualDisplayID ?? CGMainDisplayID())
            }

            await desktopContext.updateVirtualDisplaySnapshotResolution(virtualResolution)
            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 8, delayMs: 60)
            try await desktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: virtualResolution
            )

            let inputGeometry = updateDesktopInputGeometry(
                streamID: streamID,
                physicalBounds: refreshDesktopPrimaryPhysicalBounds(),
                virtualResolution: virtualResolution
            )

            let dimensionToken = await desktopContext.getDimensionToken()
            let encodedDimensions = await desktopContext.getEncodedDimensions()
            let displayResolution = await currentDesktopStartedResolution(
                fallback: CGSize(width: encodedDimensions.width, height: encodedDimensions.height)
            )
            desktopPresentationGeneration &+= 1
            let message = DesktopStreamStartedMessage(
                streamID: streamID,
                desktopSessionID: desktopSessionID,
                width: Int(displayResolution.width),
                height: Int(displayResolution.height),
                frameRate: await desktopContext.getTargetFrameRate(),
                codec: await desktopContext.getCodec(),
                displayCount: 1,
                dimensionToken: dimensionToken,
                acceptedMediaMaxPacketSize: await desktopContext.getMediaMaxPacketSize(),
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
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to restart desktop virtual display after display topology change: "
            )
        }
    }

    func currentDesktopVirtualDisplayPixelResolution(fallback: CGSize? = nil) async -> CGSize? {
        let liveResolution = desktopVirtualDisplayID.flatMap {
            CGVirtualDisplayBridge.currentDisplayModeSizes($0)?.pixel
        }
        let sharedSnapshot = await SharedVirtualDisplayManager.shared.getDisplaySnapshot()
        let sharedResolution: CGSize? = if desktopUsesHostResolution {
            nil
        } else if let desktopVirtualDisplayID, sharedSnapshot?.displayID == desktopVirtualDisplayID {
            sharedSnapshot?.resolution
        } else if desktopVirtualDisplayID == nil {
            sharedSnapshot?.resolution
        } else {
            nil
        }
        let streamResolution: CGSize? = if desktopUsesHostResolution {
            nil
        } else {
            await desktopStreamContext?.getVirtualDisplaySnapshot()?.resolution
        }

        return resolvedDesktopVirtualDisplayResolution(
            livePixelResolution: liveResolution,
            sharedSnapshotResolution: sharedResolution,
            streamSnapshotResolution: streamResolution,
            cachedResolution: desktopMirroredVirtualResolution,
            fallbackResolution: fallback
        )
    }

    @discardableResult
    func updateDesktopInputGeometry(
        streamID: StreamID,
        physicalBounds: CGRect? = nil,
        virtualResolution: CGSize?
    )
    -> DesktopInputGeometryRefreshResult {
        let resolvedPhysicalBounds = physicalBounds ?? refreshDesktopPrimaryPhysicalBounds()
        let resolvedVirtualResolution = validDesktopVirtualResolution(virtualResolution)
        desktopMirroredVirtualResolution = resolvedVirtualResolution
        let inputBounds = resolvedDesktopInputBounds(
            physicalBounds: resolvedPhysicalBounds,
            virtualResolution: resolvedVirtualResolution
        )
        inputStreamCacheActor.updateWindowFrame(streamID, newFrame: inputBounds)
        return DesktopInputGeometryRefreshResult(
            physicalBounds: resolvedPhysicalBounds,
            virtualResolution: resolvedVirtualResolution,
            inputBounds: inputBounds
        )
    }

    private func resetDesktopCaptureForUnmanagedResolutionChangeIfNeeded(
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
            let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
            try await desktopContext.hardResetDesktopDisplayCapture(
                displayWrapper: captureDisplay,
                resolution: virtualResolution
            )
            updateDesktopInputGeometry(
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
