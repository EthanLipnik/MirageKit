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
        let refreshedDisplayBounds = resolveDesktopDisplayBounds()
        let refreshedPhysicalBounds = refreshDesktopPrimaryPhysicalBounds()
        let virtualResolution = await desktopStreamContext?.getVirtualDisplaySnapshot()?.resolution
        desktopMirroredVirtualResolution = virtualResolution
        let refreshedInputBounds = resolvedDesktopInputBounds(
            physicalBounds: refreshedPhysicalBounds,
            virtualResolution: virtualResolution
        )
        inputStreamCacheActor.updateWindowFrame(desktopStreamID, newFrame: refreshedInputBounds)

        let displayBoundsChanged = refreshedDisplayBounds != previousDisplayBounds
        let physicalBoundsChanged = refreshedPhysicalBounds != previousPrimaryPhysicalBounds
        guard displayBoundsChanged || physicalBoundsChanged else { return }
        let displaySizeChanged = refreshedDisplayBounds?.size != previousDisplayBounds?.size
        let physicalSizeChanged = refreshedPhysicalBounds.size != previousPrimaryPhysicalBounds?.size

        MirageLogger.host(
            "Desktop display topology changed; refreshed input bounds to \(refreshedInputBounds)"
        )

        if displaySizeChanged || physicalSizeChanged {
            await sendStreamScaleUpdate(streamID: desktopStreamID)
        }
    }
}

#endif
