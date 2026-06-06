//
//  StreamContext+Streaming+Lifecycle.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Stream encoding lifecycle and shutdown helpers.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    /// Pauses encoding while the client is backgrounded and drops queued frames that would arrive stale.
    func pauseForClientBackground() async {
        let wasEncoding = shouldEncodeFrames
        shouldEncodeFrames = false
        frameInbox.discardAll()
        await packetSender?.resetQueue(reason: "client background pause")
        if wasEncoding {
            MirageLogger.stream("Stream \(streamID) paused for client background")
        } else {
            MirageLogger.stream("Stream \(streamID) cleaned up repeated client background pause")
        }
    }

    /// Resumes foreground encoding from a fresh keyframe so the client does not present stale deltas.
    func resumeAfterClientForeground() async {
        let wasEncoding = shouldEncodeFrames
        shouldEncodeFrames = true
        lastKeyframeTime = 0
        frameInbox.discardAll()
        await packetSender?.resetQueue(reason: "client foreground resume")

        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        keyframeInFlightFrameNumber = nil
        await restoreRuntimeBudgetAfterClientForegroundResume()

        let now = CFAbsoluteTimeGetCurrent()
        startFrameChainRepair(
            reason: "client-foreground-resume",
            now: now
        )
        let scheduledRecoveryKeyframe = await scheduleCoalescedRecoveryKeyframe(
            reason: "Client foreground resume",
            resetFrameNumber: true,
            noteLoss: true,
            requiresReset: true,
            ignoreExistingInFlight: true,
            bypassesRecoveryCooldown: true
        )
        MirageLogger.stream(
            "Stream \(streamID) resumed after client foreground " +
                "wasEncoding=\(wasEncoding) recoveryKeyframeScheduled=\(scheduledRecoveryKeyframe)"
        )
    }

    private func restoreRuntimeBudgetAfterClientForegroundResume() async {
        guard runtimeQualityAdjustmentEnabled else { return }

        let ceilingBitrate = max(
            1,
            bitrateAdaptationCeiling ??
                requestedTargetBitrate ??
                startupBitrate ??
                currentTargetBitrateBps ??
                encoderConfig.bitrate ??
                realtimeMinimumBitrateFloorBps
        )
        let restartBitrate = min(
            ceilingBitrate,
            max(
                realtimeMinimumBitrateFloorBps,
                currentTargetBitrateBps ?? 0,
                requestedTargetBitrate ?? 0,
                startupBitrate ?? 0,
                encoderConfig.bitrate ?? 0
            )
        )

        adaptivePFrameController = HostAdaptivePFrameController()
        realtimeRuntimeQualityCeiling = nil
        realtimeRuntimeBitrateCeilingBps = nil
        realtimeEncoderRateHintBps = nil
        realtimeSenderPacingBitrateBps = nil
        realtimePressureState = .observing
        realtimePressureReason = nil
        realtimeLastLoggedState = .observing
        realtimeLastLoggedBitrateCeilingBps = nil
        pendingEmergencyKeyframeQuality = nil

        if restartBitrate > 0 {
            await applyRealtimeBudgetBitrate(
                restartBitrate,
                ceilingBitrateBps: ceilingBitrate,
                encoderRateHintBps: restartBitrate,
                senderPacingBitrateBps: restartBitrate,
                minimumBitrateFloorBps: realtimeMinimumBitrateFloorBps,
                reason: HostAdaptivePFrameController.Reason.startup.rawValue
            )
        }

        let previousQuality = activeQuality
        qualityCeiling = resolvedRuntimeQualityCeiling(for: min(configuredQualityCeiling, compressionQualityCeiling))
        qualityFloor = resolvedRuntimeQualityFloor(for: qualityCeiling)
        keyframeQualityFloor = resolvedRuntimeKeyframeQualityFloor(
            for: min(encoderConfig.keyframeQuality, qualityCeiling)
        )
        activeQuality = max(activeQuality, qualityFloor, min(configuredQualityCeiling, qualityCeiling))
        guard abs(Double(activeQuality - previousQuality)) > 0.0001 else { return }

        await encoder?.updateQuality(activeQuality)
        MirageLogger.metrics(
            "Client foreground resume restored runtime quality for stream \(streamID): " +
                "active=\(activeQuality.formatted(.number.precision(.fractionLength(2)))) " +
                "ceiling=\(qualityCeiling.formatted(.number.precision(.fractionLength(2)))) " +
                "bitrate=\(restartBitrate)"
        )
    }

    /// Stops packet production during a desktop resize preflight while keeping capture state available.
    func suspendEncodingForDesktopResize() async {
        guard !encodingSuspendedForResize else { return }
        encodingSuspendedForResize = true
        shouldEncodeFrames = false
        frameInbox.discardAll()
        resetPipelineStateForReconfiguration(reason: "desktop resize preflight pause")
        await packetSender?.resetQueue(reason: "desktop resize preflight pause")
        MirageLogger.stream("Desktop resize preflight: encoding suspended")
    }

    /// Reopens encoding after desktop resize and schedules a reset keyframe for the new dimensions.
    func resumeEncodingAfterDesktopResize() async {
        guard encodingSuspendedForResize else { return }
        encodingSuspendedForResize = false
        lastKeyframeTime = 0
        shouldEncodeFrames = true
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize resume",
            resetFrameNumber: true,
            noteLoss: true,
            ignoreExistingInFlight: true,
            supersedesInFlightGeometry: true,
            bypassesRecoveryCooldown: true
        )
        MirageLogger.stream("Desktop resize completion: encoding resumed")
    }

    /// Releases the startup gate after datagram registration and primes the encoder before any frames drain.
    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastKeyframeTime = 0
        if !startupRegistrationLogged {
            startupRegistrationLogged = true
            logStartupEvent("datagram registration confirmed")
        }
        enableStartupTransportProtection(now: now)

        // Configure the encoder before allowing frames through. The awaited
        // call can suspend this actor, so queued drain tasks must not see
        // shouldEncodeFrames until the startup keyframe state is in place.
        await scheduleCoalescedStartupKeyframe(
            reason: "Startup registration confirmed",
            resetFrameNumber: true
        )

        let cachedStartupFrame = self.cachedStartupFrame
        self.cachedStartupFrame = nil
        startupFrameCachingEnabled = false
        var requiresExplicitDrainKick = frameInbox.hasPending
        if let cachedStartupFrame, !frameInbox.hasPending {
            let injectedFrameInfo = CapturedFrameInfo(
                contentRect: cachedStartupFrame.info.contentRect,
                dirtyPercentage: cachedStartupFrame.info.dirtyPercentage,
                isIdleFrame: false
            )
            let injectedFrame = CapturedFrame(
                pixelBuffer: cachedStartupFrame.pixelBuffer,
                presentationTime: cachedStartupFrame.presentationTime,
                duration: cachedStartupFrame.duration,
                captureTime: cachedStartupFrame.captureTime,
                info: injectedFrameInfo
            )
            frameInbox.enqueueWithoutSchedulingSignal(injectedFrame)
            requiresExplicitDrainKick = true
            MirageLogger.stream(
                "Queued cached pre-registration frame for startup stream \(streamID) idle=\(cachedStartupFrame.info.isIdleFrame)"
            )
        }

        shouldEncodeFrames = true
        MirageLogger.signpostEvent(.stream, "Startup.EncodingEnabled", "stream=\(streamID)")
        MirageLogger.stream("datagram registration confirmed, encoding resumed")
        if requiresExplicitDrainKick {
            Task(priority: .userInitiated) { await self.processPendingFrames() }
        } else {
            scheduleProcessingIfNeeded()
        }
    }

    /// Tears down capture, packet sending, encoder state, and any virtual-display window binding.
    func stop() async {
        guard isRunning else { return }
        isRunning = false
        disableStartupTransportProtection()

        await captureEngine?.stopCapture()
        captureEngine = nil
        frameInbox.discardAll()
        cachedStartupFrame = nil
        startupFrameCachingEnabled = false
        dependencyRecoveryKeyframeRetryTask?.cancel()
        dependencyRecoveryKeyframeRetryTask = nil
        frameChainRepairKeyframeRetryTask?.cancel()
        frameChainRepairKeyframeRetryTask = nil

        if useVirtualDisplay {
            let expectedOwner: WindowSpaceManager.WindowBindingOwner?
            if windowID != 0 {
                expectedOwner = WindowSpaceManager.WindowBindingOwner(
                    streamID: streamID
                )
            } else {
                expectedOwner = nil
            }
            await WindowSpaceManager.shared.restoreWindowSilently(
                windowID,
                expectedOwner: expectedOwner
            )
            virtualDisplayContext = nil
            virtualDisplayVisibleBounds = .zero
            virtualDisplayCaptureSourceRect = .zero
            virtualDisplayCapturePresentationRect = .zero
        }
        useVirtualDisplay = false

        let boundaryLog = streamBoundaryLog(phase: "end", kind: streamKind.rawValue)
        await packetSender?.stop()
        packetSender = nil

        await encoder?.stopEncoding()

        encoder = nil
        trafficLightMaskGeometryCache = nil
        isAppStream = false
        applicationProcessID = 0

        MirageLogger.stream(boundaryLog)
        MirageLogger.stream("Stopped stream \(streamID)")
    }
}

#endif
