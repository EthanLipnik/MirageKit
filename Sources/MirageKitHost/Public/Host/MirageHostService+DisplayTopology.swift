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
        let previousVirtualResolution = desktopMirroredVirtualResolution
        let refreshedDisplayBounds = resolveDesktopDisplayBounds()
        let refreshedPhysicalBounds = refreshDesktopPrimaryPhysicalBounds()
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
        guard displayBoundsChanged || physicalBoundsChanged || virtualResolutionChanged else { return }
        let displaySizeChanged = refreshedDisplayBounds?.size != previousDisplayBounds?.size
        let physicalSizeChanged = refreshedPhysicalBounds.size != previousPrimaryPhysicalBounds?.size

        MirageLogger.host(
            "Desktop display topology changed; refreshed input bounds to \(geometry.inputBounds)"
        )

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
