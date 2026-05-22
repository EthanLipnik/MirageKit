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
        guard shouldEncodeFrames else { return }
        shouldEncodeFrames = false
        frameInbox.discardAll()
        await packetSender?.resetQueue(reason: "client background pause")
        MirageLogger.stream("Stream \(streamID) paused for client background")
    }

    /// Resumes foreground encoding from a fresh keyframe so the client does not present stale deltas.
    func resumeAfterClientForeground() async {
        guard !shouldEncodeFrames else { return }
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if let encoder {
            await encoder.resetFrameNumber()
            await encoder.forceKeyframe()
        }
        shouldEncodeFrames = true
        MirageLogger.stream("Stream \(streamID) resumed after client foreground")
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
        smoothedDirtyPercentage = 0
        shouldEncodeFrames = true
        await scheduleCoalescedRecoveryKeyframe(
            reason: "Desktop resize resume",
            resetFrameNumber: true,
            noteLoss: true,
            ignoreExistingInFlight: true
        )
        MirageLogger.stream("Desktop resize completion: encoding resumed")
    }

    /// Releases the startup gate after UDP registration and primes the encoder before any frames drain.
    func allowEncodingAfterRegistration() async {
        guard !shouldEncodeFrames else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastKeyframeTime = 0
        smoothedDirtyPercentage = 0
        if !startupRegistrationLogged {
            startupRegistrationLogged = true
            logStartupEvent("UDP registration confirmed")
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
        MirageLogger.stream("UDP registration confirmed, encoding resumed")
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

        await packetSender?.stop()
        packetSender = nil

        await encoder?.stopEncoding()

        encoder = nil
        trafficLightMaskGeometryCache = nil
        isAppStream = false
        applicationProcessID = 0

        MirageLogger.stream("Stopped stream \(streamID)")
    }
}

#endif
