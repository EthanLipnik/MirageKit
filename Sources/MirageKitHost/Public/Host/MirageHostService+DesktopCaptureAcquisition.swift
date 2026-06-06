//
//  MirageHostService+DesktopCaptureAcquisition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

func acceptedDesktopContractDisplayScaleFactor(
    displayPixelResolution: CGSize,
    presentationResolution: CGSize,
    fallbackScaleFactor: CGFloat
) -> CGFloat {
    let normalizedPresentationResolution = MirageMedia.MirageStreamGeometry.normalizedLogicalSize(presentationResolution)
    guard normalizedPresentationResolution.width > 0,
          normalizedPresentationResolution.height > 0,
          displayPixelResolution.width > 0,
          displayPixelResolution.height > 0 else {
        return max(1.0, fallbackScaleFactor)
    }

    let widthScale = displayPixelResolution.width / normalizedPresentationResolution.width
    let heightScale = displayPixelResolution.height / normalizedPresentationResolution.height
    guard widthScale.isFinite,
          heightScale.isFinite,
          widthScale > 0,
          heightScale > 0 else {
        return max(1.0, fallbackScaleFactor)
    }

    return max(1.0, (widthScale + heightScale) * 0.5)
}

extension MirageHostService {
    /// Resolves the desktop capture context, preferring a virtual display and falling back to main-display capture.
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

        let startupBudget = DesktopVirtualDisplayStartupBudget(maxDuration: 10.0)
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
                let context = try await platformVirtualDisplayBackend.acquireDisplayForConsumer(
                    .desktopStream,
                    resolution: attempt.backingScale.pixelResolution,
                    refreshRate: attempt.refreshRate,
                    colorSpace: attempt.colorSpace,
                    allowActiveUpdate: true,
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
                lastVirtualDisplayError = MirageCore.MirageError.protocolError("Display mirroring target did not stabilize")
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
        return try await acquireFallbackMainDisplayDesktopCaptureContext(
            request,
            lastVirtualDisplayError: lastVirtualDisplayError,
            logDesktopStartStep: logDesktopStartStep
        )
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
            containerSize: request.displayResolution
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
            usesDisplayRefreshCadence: nil,
            acceptedDisplayScaleFactor: fallback.scaleFactor
        )
    }

    /// Falls back to main-display capture after virtual display acquisition fails.
    func acquireFallbackMainDisplayDesktopCaptureContext(
        _ request: DesktopCaptureAcquisitionRequest,
        lastVirtualDisplayError: (any Error)?,
        logDesktopStartStep: (String) -> Void
    ) async throws -> DesktopCaptureContext {
        if let lastVirtualDisplayError {
            MirageLogger.host(
                "Desktop virtual display acquisition failed; falling back to main display capture: " +
                    "\(lastVirtualDisplayError)"
            )
        } else {
            MirageLogger.host("Desktop virtual display acquisition produced no capture context; falling back to main display")
        }

        await platformVirtualDisplayBackend.releaseDisplayForConsumer(.desktopStream)
        return try await acquireMainDisplayDesktopCaptureContext(
            request,
            reason: "virtual_display_startup_failed",
            startupStage: "after main display fallback acquisition",
            mirroringStage: "after main display fallback mirroring",
            successLogPrefix: "main display fallback",
            configureMirroring: request.mode == .unified,
            logDesktopStartStep: logDesktopStartStep
        )
    }

    /// Finishes virtual-display desktop capture acquisition after a display snapshot is reserved.
    func finishDesktopVirtualDisplayCaptureAcquisition(
        _ request: DesktopCaptureAcquisitionRequest,
        attempt: DesktopVirtualDisplayStartupAttempt,
        displayContext context: MirageHostVirtualDisplaySnapshot,
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
        let cadenceValidation = await platformVirtualDisplayBackend.validateDisplayCadence(
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
            presentationResolution: request.displayResolution,
            virtualDisplaySnapshot: context,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence,
            acceptedDisplayScaleFactor: acceptedDesktopContractDisplayScaleFactor(
                displayPixelResolution: context.resolution,
                presentationResolution: request.displayResolution,
                fallbackScaleFactor: context.scaleFactor
            )
        )
    }

    /// Caches desktop virtual-display geometry used by capture, input, and cursor mapping.
    func cacheDesktopVirtualDisplayGeometry(
        _ request: DesktopCaptureAcquisitionRequest,
        displayContext context: MirageHostVirtualDisplaySnapshot,
        logDesktopStartStep: (String) -> Void
    ) async throws {
        desktopVirtualDisplayID = context.displayID
        desktopCaptureSource = .virtualDisplay
        var resolvedBounds = await platformVirtualDisplayBackend.displayBounds
        try await ensureDesktopStreamSetupCanContinue(
            clientContext: request.clientContext,
            startupRequestID: request.startupRequestID,
            mode: request.mode,
            stage: "after virtual display bounds lookup"
        )
        if resolvedBounds == nil { resolvedBounds = resolveDesktopDisplayBounds() }
        guard let bounds = resolvedBounds else {
            throw MirageCore.MirageError.protocolError("Desktop stream display exists but couldn't get bounds")
        }
        desktopDisplayBounds = bounds
        sharedVirtualDisplayGeneration = await platformVirtualDisplayBackend.currentDisplayGeneration
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
        displayContext context: MirageHostVirtualDisplaySnapshot,
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
                logDesktopStartStep("display mirroring unavailable; falling back to main display capture")
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
        await platformVirtualDisplayBackend.releaseDisplayForConsumer(.desktopStream)
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
