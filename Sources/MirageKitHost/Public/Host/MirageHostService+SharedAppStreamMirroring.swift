//
//  MirageHostService+SharedAppStreamMirroring.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Shared virtual-display mirroring for app and window streams.
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
    /// Acquires the shared virtual display used for app streams and mirrors it into the desktop arrangement.
    func ensureSharedAppStreamMirroring(
        preset: MirageMedia.MirageDisplaySizePreset,
        refreshRate: Int,
        colorSpace: MirageMedia.MirageColorSpace,
        mirrorPhysicalDisplays: Bool = true
    )
    async throws -> MirageHostVirtualDisplaySnapshot {
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
        let snapshot = try await platformVirtualDisplayBackend.acquireDisplayForConsumer(
            .appStream,
            resolution: preset.pixelResolution,
            refreshRate: refreshRate,
            colorSpace: colorSpace,
            allowActiveUpdate: false,
            creationPolicy: .adaptiveRetinaThenFallback1xAndColor,
            startupBudget: nil
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
        let sharedDisplaySnapshot = await platformVirtualDisplayBackend.displaySnapshot
        let mirroredDisplayID = displayID ?? sharedDisplaySnapshot?.displayID
        if desktopStreamID == nil, let mirroredDisplayID {
            _ = await disableDisplayMirroring(displayID: mirroredDisplayID)
        }
        await platformVirtualDisplayBackend.releaseDisplayForConsumer(.appStream)
    }
}
#endif
