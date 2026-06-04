//
//  MirageHostService+SharedAppStreamMirroring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Shared virtual-display mirroring for app and window streams.
//

import CoreGraphics
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Acquires the shared virtual display used for app streams and mirrors it into the desktop arrangement.
    func ensureSharedAppStreamMirroring(
        preset: MirageDisplaySizePreset,
        refreshRate: Int,
        colorSpace: MirageColorSpace,
        mirrorPhysicalDisplays: Bool = true
    )
    async throws -> SharedVirtualDisplayManager.DisplaySnapshot {
        var virtualDisplaySetupGuardToken: UUID?
        defer {
            if let token = virtualDisplaySetupGuardToken {
                Task { @MainActor [weak self] in
                    await self?.cancelVirtualDisplaySetupGuard(
                        token,
                        reason: "app_stream_shared_display_aborted"
                    )
                }
            }
        }

        virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
            reason: "app_stream_shared_display"
        )
        let snapshot = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
            .appStream,
            resolution: preset.pixelResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace
        )
        if mirrorPhysicalDisplays {
            _ = await setupDisplayMirroring(
                targetDisplayID: snapshot.displayID,
                expectedPixelResolution: snapshot.resolution,
                requiresResidualMirageDisplaysClear: false
            )
        } else {
            MirageLogger.host(
                "Shared app-stream display \(snapshot.displayID) acquired without physical display mirroring"
            )
        }
        if let token = virtualDisplaySetupGuardToken {
            await completeVirtualDisplaySetupGuard(
                token,
                reason: "app_stream_shared_display"
            )
            virtualDisplaySetupGuardToken = nil
        }
        return snapshot
    }

    /// Releases the app-stream shared display and restores mirroring when no app streams remain.
    func teardownSharedAppStreamMirroringIfIdle(displayID: CGDirectDisplayID?) async {
        guard activeStreams.isEmpty else { return }
        let sharedDisplaySnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot
        let mirroredDisplayID = displayID ?? sharedDisplaySnapshot?.displayID
        if desktopStreamID == nil, let mirroredDisplayID {
            _ = await disableDisplayMirroring(displayID: mirroredDisplayID)
        }
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.appStream)
    }
}
#endif
