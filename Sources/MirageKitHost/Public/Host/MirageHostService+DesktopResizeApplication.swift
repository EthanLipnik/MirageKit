//
//  MirageHostService+DesktopResizeApplication.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Completes a resize request whose requested display and encoded geometry already match.
    func completeNoOpDesktopResize(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        context: StreamContext,
        geometry: DesktopResizeResolvedGeometry,
        logContext: DesktopResizeLogContext
    )
    async throws {
        desktopRequestedScaleFactor = geometry.requestedDisplayScaleFactor
        await context.updateDesktopResizeGeometryRequest(
            requestedStreamScale: geometry.requestedStreamScale,
            encoderMaxWidth: geometry.encoderMaxWidth,
            encoderMaxHeight: geometry.encoderMaxHeight
        )
        MirageLogger.host(
            "Desktop stream resize skipped (already " +
                "\(logContext.logicalResolutionText) " +
                "\(logContext.pixelResolutionText), " +
                "encoded \(logContext.encodedResolutionText) @\(geometry.refreshRate)Hz, " +
                "transition=\(logContext.transitionIDText))"
        )
        try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
        await sendDesktopResizeCompletion(
            streamID: streamID,
            request: request,
            context: context,
            outcome: .noChange
        )
    }

    /// Updates encoded geometry without recreating the desktop virtual display.
    func completeEncodedOnlyDesktopResize(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        context: StreamContext,
        geometry: DesktopResizeResolvedGeometry,
        logContext: DesktopResizeLogContext,
        setupGuardToken: UUID?
    )
    async throws -> UUID? {
        try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
        try await context.updateStreamScale(geometry.requestedStreamScale)
        let primaryBounds = refreshDesktopPrimaryPhysicalBounds()
        let inputGeometry = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: primaryBounds,
            virtualResolution: geometry.pixelResolution
        )
        if let setupGuardToken {
            await completeVirtualDisplaySetupGuard(
                setupGuardToken,
                reason: "desktop_resize"
            )
        }
        MirageLogger.host(
            "Desktop stream resize updated encoded geometry to " +
                "\(logContext.encodedResolutionText) " +
                "without display recreation (transition=\(logContext.transitionIDText), " +
                "input bounds: \(inputGeometry.inputBounds))"
        )
        return nil
    }

    /// Reconfigures or recreates the desktop virtual display for a resize request.
    func reconfigureDesktopDisplayForResize(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        geometry: DesktopResizeResolvedGeometry,
        resizeRequest: DesktopVirtualDisplayResizeRequest,
        mirroringPlan: DesktopResizeMirroringPlan,
        preResizeSnapshot: SharedVirtualDisplayManager.DisplaySnapshot?,
        setupGuardToken: inout UUID?,
        shouldRestoreMirroring: inout Bool,
        suspendedMirroringDisplayID: inout CGDirectDisplayID?,
        logContext: DesktopResizeLogContext
    )
    async throws -> StreamContext {
        if desktopResizeShouldSuspendMirroring(
            plan: mirroringPlan,
            updateOutcome: .updatedInPlace
        ), let displayID = preResizeSnapshot?.displayID {
            await suspendDisplayMirroringForResize(targetDisplayID: displayID)
            suspendedMirroringDisplayID = displayID
            shouldRestoreMirroring = true
        }

        var updateResult = try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
            for: .desktopStream,
            newResolution: geometry.pixelResolution,
            refreshRate: geometry.refreshRate,
            resizeRequest: resizeRequest,
            allowRecreation: false
        )

        if updateResult.outcome == .requiresRecreation {
            if !shouldRestoreMirroring, desktopResizeShouldSuspendMirroring(
                plan: mirroringPlan,
                updateOutcome: updateResult.outcome
            ), let displayID = preResizeSnapshot?.displayID {
                await suspendDisplayMirroringForResize(targetDisplayID: displayID)
                suspendedMirroringDisplayID = displayID
                shouldRestoreMirroring = true
            }
            try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
            updateResult = try await SharedVirtualDisplayManager.shared.updateDisplayResolution(
                for: .desktopStream,
                newResolution: geometry.pixelResolution,
                refreshRate: geometry.refreshRate,
                resizeRequest: resizeRequest,
                allowRecreation: true
            )
        }

        try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
        guard let postResizeSnapshot = await SharedVirtualDisplayManager.shared.displaySnapshot else {
            throw MirageError.protocolError("Missing shared display snapshot after desktop resize")
        }

        sharedVirtualDisplayScaleFactor = max(1.0, postResizeSnapshot.scaleFactor)
        sharedVirtualDisplayGeneration = postResizeSnapshot.generation
        let effectivePixelResolution = postResizeSnapshot.resolution
        let activeDisplayID = postResizeSnapshot.displayID
        desktopVirtualDisplayID = activeDisplayID

        if shouldRestoreMirroring,
           streamID == desktopStreamID,
           desktopResizeRequiresMirroringRestoreSuccess(desktopStreamMode: desktopStreamMode) {
            let mirroringRestored = await restoreDisplayMirroringAfterResize(
                streamID: streamID,
                targetDisplayID: activeDisplayID,
                expectedPixelResolution: effectivePixelResolution
            )
            if !mirroringRestored {
                throw MirageError.protocolError(
                    "Unified desktop resize could not restore display mirroring"
                )
            }
            shouldRestoreMirroring = false
        }

        let latestDesktopContext = try await resetDesktopCaptureAfterDisplayResize(
            streamID: streamID,
            request: request,
            displaySnapshot: postResizeSnapshot
        )
        let inputGeometry = updateDesktopInputGeometry(
            streamID: streamID,
            physicalBounds: refreshDesktopPrimaryPhysicalBounds(),
            virtualResolution: effectivePixelResolution
        )
        if let token = setupGuardToken {
            await completeVirtualDisplaySetupGuard(token, reason: "desktop_resize")
            setupGuardToken = nil
        }
        if desktopResizeShouldDisableResidualMirroring(
            plan: mirroringPlan,
            generationChanged: updateResult.generationChanged,
            hasResidualMirroringState: !mirroredDesktopDisplayIDs.isEmpty || !desktopMirroringSnapshot.isEmpty
        ) {
            _ = await disableDisplayMirroring(displayID: activeDisplayID)
        }
        MirageLogger.host(
            "Desktop stream resized to " +
                "\(logContext.logicalResolutionText) " +
                "(\(Int(effectivePixelResolution.width))x\(Int(effectivePixelResolution.height)) px, " +
                "encoded \(logContext.encodedResolutionText), " +
                "transition=\(logContext.transitionIDText), input bounds: \(inputGeometry.inputBounds))"
        )
        return latestDesktopContext
    }

    /// Resets desktop capture against the resized shared display.
    func resetDesktopCaptureAfterDisplayResize(
        streamID: StreamID,
        request: DesktopResizeRequestState,
        displaySnapshot: SharedVirtualDisplayManager.DisplaySnapshot
    ) async throws -> StreamContext {
        let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 6)
        try ensureDesktopResizeTransactionCanContinue(streamID: streamID, request: request)
        guard let latestDesktopContext = desktopStreamContext else {
            throw DesktopResizeTransactionAbort.streamNoLongerActive
        }
        try await latestDesktopContext.hardResetDesktopDisplayCapture(
            displayWrapper: captureDisplay,
            resolution: displaySnapshot.resolution
        )
        if captureDisplay.display.displayID != displaySnapshot.displayID {
            MirageLogger.host(
                "Desktop resize reset captured display \(captureDisplay.display.displayID) " +
                    "while shared display is \(displaySnapshot.displayID)"
            )
        }
        await logDesktopResizeColorPipelineValidation(
            streamID: streamID,
            displaySnapshot: displaySnapshot,
            context: latestDesktopContext
        )
        return latestDesktopContext
    }
}
#endif
