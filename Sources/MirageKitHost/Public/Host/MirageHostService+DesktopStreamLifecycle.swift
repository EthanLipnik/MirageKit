//
//  MirageHostService+DesktopStreamLifecycle.swift
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
    /// Sends the desktop-started control message and returns the started display resolution.
    func sendDesktopStreamStartedNotification(
        _ notification: DesktopStreamStartedNotification,
        logDesktopStartStep: (String) -> Void
        )
        async throws -> CGSize {
        let streamStart = await notification.streamContext.streamStartSnapshot
        let encodedResolution = CGSize(
            width: streamStart.encodedDimensions.width,
            height: streamStart.encodedDimensions.height
        )
        let startedDisplayResolution = await currentDesktopStartedResolution(
            fallback: notification.captureResolution
        )
        let encodedDimensions = streamStart.encodedDimensions
        let startupAttemptID = UUID()
        desktopPresentationGeneration &+= 1
        var message = DesktopStreamStartedMessage(
            streamID: notification.streamID,
            desktopSessionID: notification.desktopSessionID,
            width: Int(startedDisplayResolution.width),
            height: Int(startedDisplayResolution.height),
            frameRate: streamStart.targetFrameRate,
            codec: streamStart.codec,
            startupAttemptID: startupAttemptID,
            displayCount: 1,
            dimensionToken: streamStart.dimensionToken,
            acceptedMediaMaxPacketSize: streamStart.mediaMaxPacketSize,
            transitionPhase: .startup,
            desktopPresentationGeneration: desktopPresentationGeneration,
            captureSource: notification.captureSource,
            allowsClientResize: notification.allowsClientResize,
            acceptedDisplayScaleFactor: notification.acceptedDisplayScaleFactor,
            presentationWidth: Int(notification.presentationResolution.width.rounded()),
            presentationHeight: Int(notification.presentationResolution.height.rounded()),
            desktopGeometryContractID: notification.desktopGeometryContractID,
            desktopGeometrySceneIdentity: notification.desktopGeometrySceneIdentity,
            desktopGeometryDisplayPixelWidth: Int(startedDisplayResolution.width.rounded()),
            desktopGeometryDisplayPixelHeight: Int(startedDisplayResolution.height.rounded()),
            desktopGeometryEncodedPixelWidth: Int(encodedDimensions.width),
            desktopGeometryEncodedPixelHeight: Int(encodedDimensions.height),
            desktopGeometryRefreshTargetHz: notification.desktopGeometryRefreshTargetHz ?? streamStart.targetFrameRate,
            presentationRole: notification.presentationRole,
            associatedAppSessionID: notification.associatedAppSessionID,
            associatedAppStartupRequestID: notification.associatedAppStartupRequestID,
            associatedBundleIdentifier: notification.associatedBundleIdentifier
        )
        let visibleBoundsSnapshot = await attachCurrentDesktopVisibleBounds(to: &message)

        do {
            registerPendingStartupAttempt(
                streamID: notification.streamID,
                startupAttemptID: startupAttemptID,
                sessionID: notification.activeClientContext.sessionID,
                clientID: notification.activeClientContext.client.id,
                kind: .desktop,
                desktopGeometryContract: message.streamReadyDesktopGeometryContract
            )
            try await notification.activeClientContext.send(.desktopStreamStarted, content: message)
            recordSentDesktopVisibleBounds(visibleBoundsSnapshot)
            startDesktopVisibleBoundsUpdates(
                streamID: notification.streamID,
                desktopSessionID: notification.desktopSessionID,
                clientContext: notification.activeClientContext
            )
            recordCurrentDesktopGeometryContract(
                contractID: notification.desktopGeometryContractID,
                sceneIdentity: notification.desktopGeometrySceneIdentity,
                presentationResolution: notification.presentationResolution,
                displayPixelResolution: startedDisplayResolution,
                encodedPixelResolution: encodedResolution,
                acceptedDisplayScaleFactor: notification.acceptedDisplayScaleFactor,
                refreshTargetHz: notification.desktopGeometryRefreshTargetHz
            )
            MirageLogger.signpostEvent(.host, "Startup.StreamStartedSent", "stream=\(notification.streamID) kind=desktop")
            logDesktopStartStep("desktopStreamStarted sent")
            return startedDisplayResolution
        } catch {
            cancelPendingStartupAttempt(streamID: notification.streamID)
            await stopDesktopStream(reason: .error, triggeredByExplicitStreamStop: false)
            MirageLogger.error(.host, error: error, message: "Failed to send desktopStreamStarted: ")
            logDesktopStartStep("desktopStreamStarted send failed")
            throw MirageError.protocolError("Desktop stream startup acknowledgement could not be delivered to the client")
        }
    }

    /// Verifies that an established desktop stream startup may still continue.
    func ensureDesktopStreamStartupCanContinue(
        streamID: StreamID,
        clientSessionID: UUID,
        startupRequestID: UUID,
        mode: MirageDesktopStreamMode,
        stage: String
    )
    async throws {
        if isStreamSetupCancelled(clientSessionID: clientSessionID, startupRequestID: startupRequestID) {
            MirageLogger.host("Desktop stream setup cancelled by client \(stage)")
            if desktopStreamID == streamID {
                await cleanupFailedDesktopStreamStartup(
                    mode: mode,
                    deferDisplayTeardown: true,
                    cleanupReason: "desktop_startup_cancelled_\(stage)"
                )
            }
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }

        guard desktopStreamID == streamID, desktopStreamContext != nil else {
            MirageLogger.host("Desktop stream startup stopped \(stage)")
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }
    }

    /// Verifies that pre-registration desktop stream setup may still continue.
    func ensureDesktopStreamSetupCanContinue(
        clientContext: ClientContext,
        startupRequestID: UUID,
        mode: MirageDesktopStreamMode,
        stage: String
    )
    async throws {
        if isStreamSetupCancelled(clientSessionID: clientContext.sessionID, startupRequestID: startupRequestID) {
            MirageLogger.host("Desktop stream setup cancelled by client \(stage)")
            await cleanupFailedDesktopStreamStartup(
                mode: mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_cancelled_\(stage)"
            )
            throw MirageError.protocolError("Desktop stream setup cancelled by client")
        }

        guard !disconnectingClientIDs.contains(clientContext.client.id),
              clientsByID[clientContext.client.id] != nil else {
            MirageLogger.host("Desktop stream client disconnected \(stage); aborting startup")
            await cleanupFailedDesktopStreamStartup(
                mode: mode,
                deferDisplayTeardown: true,
                cleanupReason: "desktop_setup_client_disconnected_\(stage)"
            )
            throw MirageError.protocolError("Desktop stream client disconnected during startup")
        }
    }

    /// Cleans up virtual display and mirroring state after a failed desktop stream startup.
    func cleanupFailedDesktopStreamStartup(
        mode: MirageDesktopStreamMode,
        deferDisplayTeardown: Bool = false,
        cleanupReason: String = "failed_desktop_startup_cleanup"
    ) async {
        let failedStreamID = desktopStreamID
        let failedContext = desktopStreamContext
        let failedVirtualDisplayID = desktopVirtualDisplayID
        let failedPrimaryDisplayID = desktopPrimaryPhysicalDisplayID

        if let failedStreamID {
            cancelPendingStartupAttempt(streamID: failedStreamID)
            streamsByID.removeValue(forKey: failedStreamID)
            mediaPathClientEvidenceByStreamID.removeValue(forKey: failedStreamID)
            streamStartupBaseTimes.removeValue(forKey: failedStreamID)
            streamStartupRegistrationLogged.remove(failedStreamID)
            transportSendErrorReported.remove(failedStreamID)
            if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: failedStreamID) {
                closeRemovedMediaStream(videoStream, streamID: failedStreamID, kind: "video")
            }
            transportRegistry.unregisterVideoStream(streamID: failedStreamID)
            inputStreamCache.remove(failedStreamID)
        }

        desktopStreamContext = nil
        desktopStreamClientContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopRequestedScaleFactor = nil
        clearCurrentDesktopGeometryContract()
        notifyActiveStreamActivityChanged()
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
        if let failedContext {
            await failedContext.stop()
        }
        if let failedStreamID {
            await deactivateAudioSourceIfNeeded(streamID: failedStreamID)
        }
        if deferDisplayTeardown {
            scheduleDeferredDesktopStartupDisplayCleanup(
                mode: mode,
                failedVirtualDisplayID: failedVirtualDisplayID,
                failedPrimaryDisplayID: failedPrimaryDisplayID,
                reason: cleanupReason
            )
        } else {
            if let vdID = failedVirtualDisplayID {
                if mode == .unified {
                    _ = await disableDisplayMirroring(displayID: vdID)
                }
                await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
            } else if !desktopMirroringSnapshot.isEmpty {
                _ = await disableDisplayMirroring(displayID: failedPrimaryDisplayID ?? CGMainDisplayID())
            }
        }
        desktopVirtualDisplayID = nil
        desktopDisplayBounds = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopPhysicalDisplayTopologySignature = nil
        desktopMirroredVirtualResolution = nil
        sharedVirtualDisplayGeneration = 0
        sharedVirtualDisplayScaleFactor = 1.0
        desktopUsesHostResolution = false
        desktopCaptureSource = .virtualDisplay
        mirroredDesktopDisplayIDs.removeAll()
        if !deferDisplayTeardown {
            await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: cleanupReason)
        }
        await syncAppListRequestDeferralForInteractiveWorkload()
        if !deferDisplayTeardown {
            await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        }
        await updateLightsOutState()
        if activeStreams.isEmpty, desktopStreamID == nil {
            await PowerAssertionManager.shared.disable()
        }
    }

    /// Schedules delayed display cleanup so system display transitions can settle first.
    func scheduleDeferredDesktopStartupDisplayCleanup(
        mode: MirageDesktopStreamMode,
        failedVirtualDisplayID: CGDirectDisplayID?,
        failedPrimaryDisplayID: CGDirectDisplayID?,
        reason: String
    ) {
        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            guard let self else { return }
            await performDeferredDesktopStartupDisplayCleanup(
                mode: mode,
                failedVirtualDisplayID: failedVirtualDisplayID,
                failedPrimaryDisplayID: failedPrimaryDisplayID,
                reason: reason
            )
        }
    }

    /// Performs delayed display cleanup for a failed desktop stream startup.
    func performDeferredDesktopStartupDisplayCleanup(
        mode: MirageDesktopStreamMode,
        failedVirtualDisplayID: CGDirectDisplayID?,
        failedPrimaryDisplayID: CGDirectDisplayID?,
        reason: String
    ) async {
        guard !Task.isCancelled, desktopStreamID == nil, desktopStreamContext == nil else {
            MirageLogger.host("Skipped deferred desktop display cleanup because a newer desktop stream is active")
            deferredDesktopStartupDisplayCleanupTask = nil
            return
        }

        if let vdID = failedVirtualDisplayID {
            if mode == .unified {
                _ = await disableDisplayMirroring(displayID: vdID)
            }
            guard !Task.isCancelled, desktopStreamID == nil, desktopStreamContext == nil else {
                MirageLogger.host("Cancelled deferred desktop startup display cleanup after mirroring restore")
                deferredDesktopStartupDisplayCleanupTask = nil
                return
            }
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)
        } else if !desktopMirroringSnapshot.isEmpty {
            _ = await disableDisplayMirroring(displayID: failedPrimaryDisplayID ?? CGMainDisplayID())
        }
        guard !Task.isCancelled, desktopStreamID == nil, desktopStreamContext == nil else {
            MirageLogger.host("Cancelled deferred desktop startup display cleanup before Space restore")
            deferredDesktopStartupDisplayCleanupTask = nil
            return
        }
        await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: reason)
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        deferredDesktopStartupDisplayCleanupTask = nil
    }

    func cancelDeferredDesktopDisplayCleanupForReuse(reason: String) {
        guard let task = deferredDesktopDisplayCleanupTask else { return }
        desktopDisplayCleanupGeneration &+= 1
        task.cancel()
        deferredDesktopDisplayCleanupTask = nil
        MirageLogger.host("Cancelled deferred desktop display cleanup for reuse: \(reason)")
    }

    func scheduleDeferredDesktopDisplayCleanup(
        mode: MirageDesktopStreamMode,
        sharedDisplayID: CGDirectDisplayID?,
        primaryDisplayID: CGDirectDisplayID?,
        hadMirroringSnapshot: Bool,
        reason: String
    ) {
        deferredDesktopDisplayCleanupTask?.cancel()
        desktopDisplayCleanupGeneration &+= 1
        let cleanupGeneration = desktopDisplayCleanupGeneration
        deferredDesktopDisplayCleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: .milliseconds(150))
            } catch {
                return
            }
            await Task.yield()
            guard !Task.isCancelled else { return }
            await performDeferredDesktopDisplayCleanup(
                mode: mode,
                sharedDisplayID: sharedDisplayID,
                primaryDisplayID: primaryDisplayID,
                hadMirroringSnapshot: hadMirroringSnapshot,
                reason: reason,
                generation: cleanupGeneration
            )
        }
    }

    func performDeferredDesktopDisplayCleanup(
        mode: MirageDesktopStreamMode,
        sharedDisplayID: CGDirectDisplayID?,
        primaryDisplayID: CGDirectDisplayID?,
        hadMirroringSnapshot: Bool,
        reason: String,
        generation: UInt64
    ) async {
        defer {
            if desktopDisplayCleanupGeneration == generation {
                deferredDesktopDisplayCleanupTask = nil
            }
        }
        guard shouldContinueDeferredDesktopDisplayCleanup(generation: generation) else {
            MirageLogger.host("Skipped deferred desktop display cleanup because a newer desktop stream is active")
            return
        }

        MirageLogger.host("Deferred desktop display cleanup started: reason=\(reason)")
        beginDesktopSharedDisplayTransition()
        defer { endDesktopSharedDisplayTransition() }

        if mode == .unified {
            if let sharedDisplayID {
                _ = await disableDisplayMirroring(displayID: sharedDisplayID)
            } else if hadMirroringSnapshot {
                _ = await disableDisplayMirroring(displayID: primaryDisplayID ?? CGMainDisplayID())
            }
        }

        await Task.yield()
        guard shouldContinueDeferredDesktopDisplayCleanup(generation: generation) else {
            MirageLogger.host("Deferred desktop display cleanup cancelled after mirroring restore")
            return
        }

        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.desktopStream)

        guard shouldContinueDeferredDesktopDisplayCleanup(generation: generation) else {
            MirageLogger.host("Deferred desktop display cleanup cancelled after display release")
            return
        }

        await finishDesktopSpaceRestoreAfterDisplayTeardown(reason: reason)

        guard shouldContinueDeferredDesktopDisplayCleanup(generation: generation) else {
            MirageLogger.host("Deferred desktop display cleanup cancelled after Space restore")
            return
        }

        if activeStreams.isEmpty { await PowerAssertionManager.shared.disable() }
        await syncAppListRequestDeferralForInteractiveWorkload()
        await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
        MirageLogger.host("Deferred desktop display cleanup finished")
    }

    func shouldContinueDeferredDesktopDisplayCleanup(generation: UInt64) -> Bool {
        Self.shouldContinueDeferredDesktopDisplayCleanup(
            cleanupGeneration: generation,
            currentGeneration: desktopDisplayCleanupGeneration,
            isCancelled: Task.isCancelled,
            hasActiveDesktopStream: desktopStreamID != nil || desktopStreamContext != nil
        )
    }

    nonisolated static func shouldContinueDeferredDesktopDisplayCleanup(
        cleanupGeneration: UInt64,
        currentGeneration: UInt64,
        isCancelled: Bool,
        hasActiveDesktopStream: Bool
    ) -> Bool {
        !isCancelled &&
            cleanupGeneration == currentGeneration &&
            !hasActiveDesktopStream
    }

    /// Stops the active desktop stream and restores host display state.
    func stopDesktopStream(
        reason: DesktopStreamStopReason = .clientRequested,
        triggeredByExplicitStreamStop: Bool = true
    ) async {
        inputController.clearAllModifiers()
        stopDesktopVisibleBoundsUpdates()

        guard let streamID = desktopStreamID else {
            if desktopStreamContext != nil || desktopVirtualDisplayID != nil || desktopStreamClientContext != nil {
                MirageLogger.host("Stopping partial desktop stream startup state without an established stream ID")
                await cleanupFailedDesktopStreamStartup(mode: desktopStreamMode)
            }
            await HostDesktopStreamTerminationTracker.shared.clearDesktopStreamMarker()
            return
        }
        deferredDesktopStartupDisplayCleanupTask?.cancel()
        deferredDesktopStartupDisplayCleanupTask = nil

        let stoppedDesktopSessionID = desktopSessionID
        let stoppedClientContext = desktopStreamClientContext
        let stoppedContext = desktopStreamContext
        let stoppedMode = desktopStreamMode
        let stoppedPrimaryDisplayID = desktopPrimaryPhysicalDisplayID
        let hadMirroringSnapshot = !desktopMirroringSnapshot.isEmpty
        MirageLogger.host(
            "Stopping desktop stream: streamID=\(streamID), session=\(stoppedDesktopSessionID?.uuidString ?? "nil"), reason=\(reason)"
        )
        beginDesktopSharedDisplayTransition()
        defer { endDesktopSharedDisplayTransition() }
        desktopPresentationGeneration = 0
        resetDesktopResizeTransactionState()
        desktopDisplayTopologyRefreshTask?.cancel()
        desktopDisplayTopologyRefreshTask = nil

        let sharedDisplayID = await SharedVirtualDisplayManager.shared.displayID

        cancelPendingStartupAttempt(streamID: streamID)
        desktopStreamContext = nil
        desktopStreamID = nil
        desktopSessionID = nil
        desktopStreamClientContext = nil
        notifyActiveStreamActivityChanged()
        streamsByID.removeValue(forKey: streamID)
        mediaPathClientEvidenceByStreamID.removeValue(forKey: streamID)
        streamStartupBaseTimes.removeValue(forKey: streamID)
        streamStartupRegistrationLogged.remove(streamID)
        transportSendErrorReported.remove(streamID)
        if let videoStream = loomVideoStreamsByStreamID.removeValue(forKey: streamID) {
            closeRemovedMediaStream(videoStream, streamID: streamID, kind: "video")
        }
        transportRegistry.unregisterVideoStream(streamID: streamID)
        inputStreamCache.remove(streamID)

        if let stoppedContext { await stoppedContext.stop() }

        if let clientContext = stoppedClientContext,
           let stoppedDesktopSessionID {
            let message = DesktopStreamStoppedMessage(
                streamID: streamID,
                desktopSessionID: stoppedDesktopSessionID,
                reason: reason
            )
            do {
                try await clientContext.send(.desktopStreamStopped, content: message)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send desktopStreamStopped: ")
            }
        }

        desktopDisplayBounds = nil
        desktopVirtualDisplayID = nil
        desktopPrimaryPhysicalDisplayID = nil
        desktopPrimaryPhysicalBounds = nil
        desktopMirroredVirtualResolution = nil
        desktopRequestedScaleFactor = nil
        desktopUsesHostResolution = false
        desktopCaptureSource = .virtualDisplay
        sharedVirtualDisplayScaleFactor = 2.0
        desktopStreamMode = .unified
        desktopCursorPresentation = .simulatedCursor
        await deactivateAudioSourceIfNeeded(streamID: streamID)

        await syncAppListRequestDeferralForInteractiveWorkload()

        syncSharedClipboardState()
        await updateLightsOutState()
        lockHostIfStreamingStopped(triggeredByExplicitStreamStop: triggeredByExplicitStreamStop)
        scheduleDeferredDesktopDisplayCleanup(
            mode: stoppedMode,
            sharedDisplayID: sharedDisplayID,
            primaryDisplayID: stoppedPrimaryDisplayID,
            hadMirroringSnapshot: hadMirroringSnapshot,
            reason: "desktop_stream_stop"
        )

        MirageLogger.host("Desktop stream stopped; display cleanup deferred")
    }
}

#endif
