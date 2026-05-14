//
//  MirageHostService+DesktopCaptureAcquisition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension MirageHostService {
    /// Resolves the desktop capture context, using main-display capture only when explicitly requested.
    func acquireDesktopCaptureContext(
        _ request: DesktopCaptureAcquisitionRequest,
        config: inout MirageEncoderConfiguration,
        virtualDisplayStartupSession: inout DesktopVirtualDisplayStartupSession,
        virtualDisplaySetupGuardToken: inout UUID?,
        logDesktopStartStep: (String) -> Void
    )
    async throws -> DesktopCaptureContext {
        var acquiredCaptureContext: DesktopCaptureContext?
        var lastVirtualDisplayError: Error?
        let startupBudget = DesktopVirtualDisplayStartupBudget(maxDuration: 10.0)

        if request.usesHostResolution {
            return try await acquireMainDisplayDesktopCaptureContext(
                request,
                reason: "host_resolution_requested",
                startupStage: "after host-resolution main display acquisition",
                mirroringStage: "after host-resolution mirroring",
                successLogPrefix: "host-resolution",
                configureMirroring: true,
                logDesktopStartStep: logDesktopStartStep
            )
        }

        virtualDisplaySetupGuardToken = await beginVirtualDisplaySetupGuard(
            reason: "desktop_stream_start"
        )

        var attemptIndex = 0
        acquisitionLoop: while attemptIndex < request.startupAttempts.count {
            let attempt = request.startupAttempts[attemptIndex]
            if startupBudget.isExpired {
                MirageLogger.error(.host, "Desktop virtual display acquisition budget exceeded (10s)")
                lastVirtualDisplayError = DesktopVirtualDisplayStartupBudgetExceeded()
                break acquisitionLoop
            }

            try await ensureDesktopStreamSetupCanContinue(
                clientContext: request.clientContext,
                startupRequestID: request.startupRequestID,
                mode: request.mode,
                stage: "during acquisition loop"
            )

            let attemptConfig = config.withInternalOverrides(colorSpace: attempt.colorSpace)
            logDesktopVirtualDisplayAttempt(attempt)

            do {
                let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                    .desktopStream,
                    resolution: attempt.backingScale.pixelResolution,
                    refreshRate: attempt.refreshRate,
                    colorSpace: attempt.colorSpace,
                    creationPolicy: .singleAttempt(hiDPI: attempt.backingScale.scaleFactor > 1.5),
                    startupBudget: startupBudget
                )
                config = attemptConfig
                logDesktopStartStep("virtual display acquired (\(context.displayID), \(attempt.label))")
                desktopVirtualDisplayID = context.displayID
                desktopCaptureSource = .virtualDisplay
                acquiredCaptureContext = try await finishDesktopVirtualDisplayCaptureAcquisition(
                    request,
                    attempt: attempt,
                    displayContext: context,
                    config: config,
                    startupBudget: startupBudget,
                    logDesktopStartStep: logDesktopStartStep
                )
                virtualDisplayStartupSession.persistIfPreferred(
                    from: context,
                    attemptedRefreshRate: attempt.refreshRate
                )
                break acquisitionLoop
            } catch is DesktopVirtualDisplayMirroringTargetUnstable {
                lastVirtualDisplayError = MirageError.protocolError("Display mirroring target did not stabilize")
                break acquisitionLoop
            } catch is DesktopVirtualDisplayStartupBudgetExceeded {
                lastVirtualDisplayError = DesktopVirtualDisplayStartupBudgetExceeded()
                await resetFailedDesktopVirtualDisplayAcquisition(
                    restoreHostResolution: request.usesHostResolution
                )
                MirageLogger.host(
                    "Desktop virtual display startup exceeded 10s budget after \(startupBudget.elapsedMilliseconds)ms"
                )
                break acquisitionLoop
            } catch {
                if isStreamSetupCancelled(
                    clientSessionID: request.clientContext.sessionID,
                    startupRequestID: request.startupRequestID
                ) || disconnectingClientIDs.contains(request.clientContext.client.id)
                    || clientsByID[request.clientContext.client.id] == nil {
                    throw error
                }

                let failureClass = virtualDisplayStartupSession.recordFailure(error)
                await resetFailedDesktopVirtualDisplayAcquisition(
                    restoreHostResolution: request.usesHostResolution
                )
                lastVirtualDisplayError = error

                if attempt.isCachedTarget {
                    clearDesktopVirtualDisplayStartupTarget(for: request.startupPlan.request)
                    MirageLogger.host(
                        "Cached desktop virtual display startup target failed; evicting cached target for current mode"
                    )
                }

                if let nextAttemptIndex = virtualDisplayStartupSession.nextRetryIndex(
                    after: failureClass,
                    attempts: request.startupAttempts,
                    currentIndex: attemptIndex
                ) {
                    logDesktopVirtualDisplayRetry(
                        attempt: attempt,
                        currentIndex: attemptIndex,
                        nextAttemptIndex: nextAttemptIndex,
                        startupAttempts: request.startupAttempts,
                        error: error
                    )
                    attemptIndex = nextAttemptIndex
                    continue
                }

                logDesktopVirtualDisplayFailClosed(error)
            }

            attemptIndex += 1
        }

        if let acquiredCaptureContext { return acquiredCaptureContext }
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        if let lastVirtualDisplayError {
            MirageLogger.error(
                .host,
                error: lastVirtualDisplayError,
                message: "Desktop virtual display acquisition failed without changing requested resolution: "
            )
            throw lastVirtualDisplayError
        }
        throw MirageError.captureSetupFailed("Desktop virtual display acquisition failed")
    }

    /// Acquires a main-display desktop capture context.
    func acquireMainDisplayDesktopCaptureContext(
        _ request: DesktopCaptureAcquisitionRequest,
        reason: String,
        startupStage: String,
        mirroringStage: String,
        successLogPrefix: String,
        configureMirroring: Bool,
        logDesktopStartStep: (String) -> Void
    )
    async throws -> DesktopCaptureContext {
        let fallback = try await mainDisplayDesktopCaptureFallback(reason: reason)
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: startupStage
        )
        applyMainDisplayDesktopCaptureFallback(fallback)
        let presentationResolution = aspectFitPixelSize(
            contentSize: fallback.resolution,
            containerSize: request.virtualDisplayResolution
        )
        if configureMirroring {
            let mirroringConfigured = await setupDisplayMirroring(
                targetDisplayID: fallback.displayID,
                expectedPixelResolution: fallback.resolution,
                requiresResidualMirageDisplaysClear: false
            )
            if mirroringConfigured {
                logDesktopStartStep("\(successLogPrefix) main display mirroring configured")
            } else {
                logDesktopStartStep("\(successLogPrefix) main display mirroring incomplete; continuing")
            }
            try await ensureDesktopStreamSetupCanContinue(
                clientContext: request.clientContext,
                startupRequestID: request.startupRequestID,
                mode: request.mode,
                stage: mirroringStage
            )
        }
        logDesktopStartStep("\(successLogPrefix) main display acquired (\(fallback.displayID))")
        return DesktopCaptureContext(
            display: fallback.display,
            resolution: fallback.resolution,
            p3CoverageStatus: nil,
            colorSpace: nil,
            captureSource: .mainDisplayFallback,
            allowsClientResize: false,
            presentationResolution: presentationResolution,
            virtualDisplaySnapshot: nil,
            usesDisplayRefreshCadence: nil
        )
    }

    /// Finishes virtual-display desktop capture acquisition after a display snapshot is reserved.
    func finishDesktopVirtualDisplayCaptureAcquisition(
        _ request: DesktopCaptureAcquisitionRequest,
        attempt: DesktopVirtualDisplayStartupAttempt,
        displayContext context: SharedVirtualDisplayManager.DisplaySnapshot,
        config: MirageEncoderConfiguration,
        startupBudget: DesktopVirtualDisplayStartupBudget,
        logDesktopStartStep: (String) -> Void
    )
    async throws -> DesktopCaptureContext {
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after virtual display acquire"
        )
        if request.mode == .secondary {
            await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(targetDisplayID: context.displayID)
            try await ensureDesktopStreamSetupCanContinue(
                clientContext: request.clientContext,
                startupRequestID: request.startupRequestID,
                mode: request.mode,
                stage: "after secondary display unmirror"
            )
        }

        let captureDisplay = try await findSCDisplayWithRetry(maxAttempts: 5, startupBudget: startupBudget)
        logDesktopStartStep("SCDisplay resolved (\(captureDisplay.display.displayID))")
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after ScreenCaptureKit display resolution"
        )

        try await cacheDesktopVirtualDisplayGeometry(
            request,
            displayContext: context,
            logDesktopStartStep: logDesktopStartStep
        )
        let didConfigureMirroring = try await configureDesktopVirtualDisplayMirroring(
            request,
            displayContext: context,
            logDesktopStartStep: logDesktopStartStep
        )
        guard didConfigureMirroring else {
            throw DesktopVirtualDisplayMirroringTargetUnstable()
        }

        if captureDisplay.display.displayID != context.displayID {
            MirageLogger.error(
                .host,
                "Desktop capture display mismatch: capture=\(captureDisplay.display.displayID), virtual=\(context.displayID)"
            )
        }
        let cadenceValidation = await SharedVirtualDisplayManager.shared.validateDisplayCadence(
            context,
            targetFrameRate: attempt.refreshRate
        )
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after display cadence validation"
        )
        let usesDisplayRefreshCadence = cadenceValidation.usesNativeDisplayCadence
        if !usesDisplayRefreshCadence {
            MirageLogger.host(
                "Desktop virtual display \(context.displayID) did not prove \(attempt.refreshRate)Hz live cadence; using explicit SCK frame interval"
            )
        }
        if context.colorSpace != config.colorSpace {
            MirageLogger.host(
                "Desktop display color space adjusted by virtual display manager: requested=\(config.colorSpace.displayName), effective=\(context.colorSpace.displayName), coverage=\(context.displayP3CoverageStatus.rawValue)"
            )
        }
        logDesktopVirtualDisplayAttemptSuccess(attempt)
        MirageLogger.host(
            "Desktop capture source: Virtual Display (capture display \(captureDisplay.display.displayID), virtual \(context.displayID), requestedColor=\(config.colorSpace.displayName), effectiveColor=\(context.colorSpace.displayName), coverage=\(context.displayP3CoverageStatus.rawValue))"
        )
        return DesktopCaptureContext(
            display: captureDisplay,
            resolution: context.resolution,
            p3CoverageStatus: context.displayP3CoverageStatus,
            colorSpace: context.colorSpace,
            captureSource: .virtualDisplay,
            allowsClientResize: true,
            presentationResolution: context.resolution,
            virtualDisplaySnapshot: context,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
    }

    /// Caches desktop virtual-display geometry used by capture, input, and cursor mapping.
    func cacheDesktopVirtualDisplayGeometry(
        _ request: DesktopCaptureAcquisitionRequest,
        displayContext context: SharedVirtualDisplayManager.DisplaySnapshot,
        logDesktopStartStep: (String) -> Void
    ) async throws {
        desktopVirtualDisplayID = context.displayID
        desktopCaptureSource = .virtualDisplay
        var resolvedBounds = await SharedVirtualDisplayManager.shared.displayBounds
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after virtual display bounds lookup"
        )
        if resolvedBounds == nil { resolvedBounds = resolveDesktopDisplayBounds() }
        guard let bounds = resolvedBounds else {
            throw MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
        }
        desktopDisplayBounds = bounds
        sharedVirtualDisplayGeneration = await SharedVirtualDisplayManager.shared.currentDisplayGeneration
        sharedVirtualDisplayScaleFactor = max(1.0, context.scaleFactor)
        logDesktopStartStep("display bounds cached")

        if desktopPrimaryPhysicalDisplayID == nil {
            let primaryDisplayID = resolvePrimaryPhysicalDisplayID() ?? CGMainDisplayID()
            desktopPrimaryPhysicalDisplayID = primaryDisplayID
            desktopPrimaryPhysicalBounds = CGDisplayBounds(primaryDisplayID)
            desktopPhysicalDisplayTopologySignature = currentPhysicalDisplayTopologySignature()
            MirageLogger.host(
                "Desktop primary physical display: \(primaryDisplayID), bounds=\(desktopPrimaryPhysicalBounds ?? .zero)"
            )
        }
    }

    /// Configures display mirroring for the acquired desktop virtual display.
    func configureDesktopVirtualDisplayMirroring(
        _ request: DesktopCaptureAcquisitionRequest,
        displayContext context: SharedVirtualDisplayManager.DisplaySnapshot,
        logDesktopStartStep: (String) -> Void
    ) async throws -> Bool {
        if request.mode == .unified {
            let mirroringConfigured = await setupDisplayMirroring(
                targetDisplayID: context.displayID,
                expectedPixelResolution: context.resolution
            )
            if mirroringConfigured {
                logDesktopStartStep("display mirroring configured")
            } else {
                logDesktopStartStep("display mirroring unavailable; aborting virtual display acquisition")
                _ = await disableDisplayMirroring(displayID: context.displayID)
                await resetFailedDesktopVirtualDisplayAcquisition(
                    restoreHostResolution: request.usesHostResolution
                )
                return false
            }
        } else {
            await unmirrorPhysicalDisplaysForWindowStreamingIfNeeded(targetDisplayID: context.displayID)
            logDesktopStartStep("display mirroring cleared/skipped (secondary display)")
        }
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after display mirroring update"
        )
        return true
    }

    /// Clears failed virtual-display acquisition state before retry or fallback.
    func resetFailedDesktopVirtualDisplayAcquisition(restoreHostResolution: Bool) async {
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        desktopVirtualDisplayID = nil
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = 1.0
        desktopDisplayBounds = nil
        desktopUsesHostResolution = restoreHostResolution
    }

    /// Applies main-display fallback state to the active desktop stream.
    func applyMainDisplayDesktopCaptureFallback(_ fallback: DesktopMainDisplayCaptureFallback) {
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = fallback.displayID
        desktopPrimaryPhysicalBounds = fallback.bounds
        desktopDisplayBounds = fallback.bounds
        desktopMirroredVirtualResolution = fallback.resolution
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = fallback.scaleFactor
        desktopUsesHostResolution = true
        desktopCaptureSource = .mainDisplayFallback
    }

}

#endif
