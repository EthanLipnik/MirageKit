//
//  StreamController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import CoreGraphics
import Foundation
import MirageKit
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

extension StreamController {
    struct AdaptiveJitterState: Sendable, Equatable {
        var holdMs: Int
        var stressStreak: Int
        var stableStreak: Int
    }

    // MARK: - Private Helpers

    func setTransportPathKind(_ kind: MirageNetworkPathKind) {
        let awdlActive = awdlExperimentEnabled && kind == .awdl
        guard awdlTransportActive != awdlActive else { return }
        awdlTransportActive = awdlActive
        if !awdlActive {
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
        }
    }

    func evaluateAdaptiveJitterHold(receivedFPS: Double) {
        guard awdlExperimentEnabled, awdlTransportActive else {
            adaptiveJitterHoldMs = 0
            adaptiveJitterStressStreak = 0
            adaptiveJitterStableStreak = 0
            return
        }

        let state = Self.nextAdaptiveJitterState(
            current: AdaptiveJitterState(
                holdMs: adaptiveJitterHoldMs,
                stressStreak: adaptiveJitterStressStreak,
                stableStreak: adaptiveJitterStableStreak
            ),
            receivedFPS: receivedFPS,
            targetFPS: decodeSchedulerTargetFPS
        )
        adaptiveJitterHoldMs = state.holdMs
        adaptiveJitterStressStreak = state.stressStreak
        adaptiveJitterStableStreak = state.stableStreak
    }

    nonisolated static func nextAdaptiveJitterState(
        current: AdaptiveJitterState,
        receivedFPS: Double,
        targetFPS: Int
    ) -> AdaptiveJitterState {
        var next = current
        let target = Double(max(1, targetFPS))
        let stress = receivedFPS < target * Self.adaptiveJitterStressThreshold
        if stress {
            next.stressStreak += 1
            next.stableStreak = 0
            if next.stressStreak >= Self.adaptiveJitterStressWindows {
                next.stressStreak = 0
                next.holdMs = min(
                    Self.adaptiveJitterHoldMaxMs,
                    next.holdMs + Self.adaptiveJitterStepUpMs
                )
            }
            return next
        }

        next.stressStreak = 0
        next.stableStreak += 1
        if next.stableStreak >= Self.adaptiveJitterStableWindows {
            next.stableStreak = 0
            next.holdMs = max(0, next.holdMs - Self.adaptiveJitterStepDownMs)
        }
        return next
    }

    func armFirstPresentedFrameAwaiter(reason: String) {
        let snapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)
        awaitingFirstPresentedFrame = true
        firstPresentedFrameBaselineSequence = snapshot.sequence
        firstPresentedFrameWaitStartTime = currentTime()
        firstPresentedFrameLastWaitLogTime = firstPresentedFrameWaitStartTime
        firstPresentedFrameLastRecoveryRequestTime = 0

        MirageLogger
            .client(
                "Waiting for first presented frame (\(reason)) for stream \(streamID), baseline sequence \(snapshot.sequence)"
            )
        startFirstPresentedFrameMonitorIfNeeded()
    }

    func stopFirstPresentedFrameMonitor() {
        firstPresentedFrameTask?.cancel()
        firstPresentedFrameTask = nil
        awaitingFirstPresentedFrame = false
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0
    }

    func markFirstFrameDecoded() async {
        let shouldNotify = !hasDecodedFirstFrame
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }

        if awaitingFirstFrameAfterResize {
            awaitingFirstFrameAfterResize = false
            MirageLogger.client("Post-resize first frame decoded for stream \(streamID)")
        }

        guard shouldNotify, let handler = onFirstFrameDecoded else { return }
        await MainActor.run {
            handler()
        }
    }

    func markFirstFramePresented() async {
        let now = currentTime()
        let wasAwaitingFirstPresentation = awaitingFirstPresentedFrame
        let waitStart = firstPresentedFrameWaitStartTime

        awaitingFirstPresentedFrame = false
        firstPresentedFrameBaselineSequence = 0
        firstPresentedFrameWaitStartTime = 0
        firstPresentedFrameLastWaitLogTime = 0
        firstPresentedFrameLastRecoveryRequestTime = 0

        if awaitingFirstFrameAfterResize {
            awaitingFirstFrameAfterResize = false
            if waitStart > 0 {
                let elapsedMs = Int((now - waitStart) * 1000)
                MirageLogger.client(
                    "Post-resize first frame presented for stream \(streamID) (+\(elapsedMs)ms)"
                )
            } else {
                MirageLogger.client("Post-resize first frame presented for stream \(streamID)")
            }
        }

        let shouldNotify = !hasPresentedFirstFrame || wasAwaitingFirstPresentation
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        if !hasDecodedFirstFrame {
            hasDecodedFirstFrame = true
        }
        guard shouldNotify, let handler = onFirstFramePresented else { return }
        await MainActor.run {
            handler()
        }
    }

    private func startFirstPresentedFrameMonitorIfNeeded() {
        guard firstPresentedFrameTask == nil else { return }
        firstPresentedFrameTask = Task { [weak self] in
            guard let self else { return }
            await self.runFirstPresentedFrameMonitor()
        }
    }

    private func runFirstPresentedFrameMonitor() async {
        defer { firstPresentedFrameTask = nil }

        while !Task.isCancelled {
            guard awaitingFirstPresentedFrame else { return }

            let snapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)
            if snapshot.sequence > firstPresentedFrameBaselineSequence {
                await markFirstFramePresented()
                return
            }

            let now = currentTime()
            maybeLogFirstPresentedFrameWait(now: now, latestSequence: snapshot.sequence)
            await maybeTriggerBootstrapFirstFrameRecovery(now: now, latestSequence: snapshot.sequence)

            do {
                try await Task.sleep(for: Self.firstPresentedFramePollInterval)
            } catch {
                return
            }
        }
    }

    private func maybeLogFirstPresentedFrameWait(now: CFAbsoluteTime, latestSequence: UInt64) {
        guard awaitingFirstPresentedFrame else { return }
        guard firstPresentedFrameWaitStartTime > 0 else { return }
        guard now - firstPresentedFrameLastWaitLogTime >= Self.firstPresentedFrameWaitLogInterval else { return }

        firstPresentedFrameLastWaitLogTime = now
        let elapsedMs = Int((now - firstPresentedFrameWaitStartTime) * 1000)
        let pendingDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        let awaitingKeyframe = reassembler.isAwaitingKeyframe()
        MirageLogger
            .client(
                "Still waiting for first presented frame for stream \(streamID) (+\(elapsedMs)ms, " +
                    "baseline=\(firstPresentedFrameBaselineSequence), latest=\(latestSequence), " +
                    "queueDepth=\(pendingDepth), awaitingKeyframe=\(awaitingKeyframe))"
            )
    }

    private func maybeTriggerBootstrapFirstFrameRecovery(
        now: CFAbsoluteTime,
        latestSequence: UInt64
    ) async {
        guard awaitingFirstPresentedFrame else { return }
        guard !hasPresentedFirstFrame else { return }
        guard !hasDecodedFirstFrame else { return }
        guard firstPresentedFrameWaitStartTime > 0 else { return }

        let elapsed = now - firstPresentedFrameWaitStartTime
        guard elapsed >= Self.firstPresentedFrameBootstrapRecoveryGrace else { return }

        if firstPresentedFrameLastRecoveryRequestTime > 0,
           now - firstPresentedFrameLastRecoveryRequestTime < Self.firstPresentedFrameRecoveryCooldown {
            return
        }

        let pendingDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        guard pendingDepth == 0 else { return }

        let awaitingKeyframe = reassembler.isAwaitingKeyframe()
        let lastPacketTime = reassembler.latestPacketReceivedTime()
        let noVideoPacketsYet = lastPacketTime == 0
        let packetStarved = !noVideoPacketsYet &&
            now - lastPacketTime >= Self.firstPresentedFramePacketStallThreshold

        guard awaitingKeyframe || noVideoPacketsYet || packetStarved else { return }

        firstPresentedFrameLastRecoveryRequestTime = now
        let elapsedMs = Int(elapsed * 1000)
        let packetAgeText: String
        if noVideoPacketsYet {
            packetAgeText = "none"
        } else {
            packetAgeText = "\(Int((now - lastPacketTime) * 1000))ms"
        }
        MirageLogger.client(
            "First-frame bootstrap watchdog triggered for stream \(streamID) (+\(elapsedMs)ms, " +
                "latest=\(latestSequence), lastPacketAge=\(packetAgeText), awaitingKeyframe=\(awaitingKeyframe)); " +
                "requesting recovery"
        )
        await handleFrameLossSignal()
    }

    func recordDecodedFrame() {
        lastDecodedFrameTime = currentTime()
        if !decodeRecoveryEscalationTimestamps.isEmpty {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
        }
        if presentationTier == .activeLive {
            startFreezeMonitorIfNeeded()
        } else {
            stopFreezeMonitor()
            lastPresentedProgressTime = currentTime()
            consecutiveFreezeRecoveries = 0
        }
    }

    func recordQueueDrop() {
        queueDropsSinceLastLog += 1
        metricsTracker.recordQueueDrop()
        let now = currentTime()
        queueDropTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
    }

    func recordDecodeThresholdEvent() {
        let now = currentTime()
        decodeThresholdTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
    }

    func maybeLogDecodeBackpressure(queueDepth: Int) {
        let now = currentTime()
        if lastBackpressureLogTime > 0,
           now - lastBackpressureLogTime < Self.backpressureLogCooldown {
            return
        }
        lastBackpressureLogTime = now
        MirageLogger.client(
            "Decode backpressure threshold hit (depth \(queueDepth)) for stream \(streamID); " +
                "continuing decode without keyframe recovery"
        )
    }

    func handleFrameLossSignal() async {
        if presentationTier == .passiveSnapshot {
            reassembler.enterKeyframeOnlyMode()
            MirageLogger.client(
                "Frame loss detected for passive stream \(streamID); requesting bounded keyframe recovery"
            )
            await requestKeyframeRecovery(reason: .frameLoss)
            return
        }

        // Bootstrap exception: if no frame has ever been presented, request keyframes so startup
        // does not deadlock on a lost initial keyframe.
        guard hasPresentedFirstFrame else {
            MirageLogger.client(
                "Frame loss detected before first presented frame for stream \(streamID); " +
                    "requesting bootstrap keyframe recovery"
            )
            reassembler.enterKeyframeOnlyMode()
            startKeyframeRecoveryLoopIfNeeded()
            await requestKeyframeRecovery(reason: .frameLoss)
            return
        }

        let isAwaitingKeyframe = reassembler.isAwaitingKeyframe()
        if isAwaitingKeyframe {
            MirageLogger.client(
                "Frame loss detected for stream \(streamID) while awaiting keyframe; deferring recovery until sustained freeze"
            )
            return
        }

        MirageLogger.client(
            "Frame loss detected for stream \(streamID); strict monotonic recovery active, waiting for explicit keyframe-await state"
        )
    }

    func requestKeyframeRecovery(reason: RecoveryReason) async {
        let now = currentTime()
        if lastRecoveryRequestDispatchTime > 0,
           now - lastRecoveryRequestDispatchTime < Self.recoveryRequestDispatchCooldown {
            return
        }
        lastRecoveryRequestDispatchTime = now

        recoveryRequestTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
        guard let handler = onKeyframeNeeded else { return }
        MirageLogger.client("Requesting recovery keyframe (\(reason.logLabel)) for stream \(streamID)")
        await MainActor.run {
            handler()
        }
    }

    func handleDecodeErrorThresholdSignal() async {
        recordDecodeThresholdEvent()

        if presentationTier == .passiveSnapshot {
            await requestSoftRecovery(reason: .decodeErrorThreshold)
            return
        }

        let now = currentTime()
        if shouldAttemptStartupDecodeErrorRecovery(now: now) {
            firstPresentedFrameLastRecoveryRequestTime = now
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Decode error threshold observed before first presented frame for stream \(streamID); forcing startup hard recovery"
            )
            await requestRecovery(reason: .decodeErrorThreshold)
            return
        }

        guard shouldAttemptDecodeErrorRecovery(now: now) else {
            maybeLogDeferredDecodeErrorRecovery(now: now)
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            return
        }

        decodeRecoveryEscalationTimestamps.append(now)
        trimDecodeRecoveryEscalationWindow(now: now)

        let shouldEscalate = decodeRecoveryEscalationTimestamps.count >= Self.decodeRecoveryEscalationThreshold
        if shouldEscalate {
            decodeRecoveryEscalationTimestamps.removeAll(keepingCapacity: false)
            MirageLogger.client(
                "Decode error storm persisted for stream \(streamID); escalating to hard recovery"
            )
            await requestRecovery(reason: .decodeErrorThreshold)
            return
        }

        await requestSoftRecovery(reason: .decodeErrorThreshold)
    }

    func shouldAttemptStartupDecodeErrorRecovery(now _: CFAbsoluteTime) -> Bool {
        guard !hasPresentedFirstFrame else { return false }
        return awaitingFirstPresentedFrame
    }

    func forcePresentationStallForTesting(now: CFAbsoluteTime? = nil) {
        let referenceNow = now ?? currentTime()
        if !hasPresentedFirstFrame {
            hasPresentedFirstFrame = true
        }
        lastPresentedProgressTime = referenceNow - Self.freezeTimeout - 0.5
    }

    func shouldAttemptDecodeErrorRecovery(now: CFAbsoluteTime) -> Bool {
        let keyframeStarved = reassembler.isAwaitingKeyframe()

        if hasPresentedFirstFrame {
            guard lastPresentedProgressTime > 0 else { return false }
            let stalledPresentation = now - lastPresentedProgressTime >= Self.freezeTimeout
            guard stalledPresentation else { return false }

            if keyframeStarved { return true }

            let lastPacketTime = reassembler.latestPacketReceivedTime()
            let hasRecentVideoPackets = lastPacketTime > 0 && now - lastPacketTime <= Self.freezeTimeout
            return hasRecentVideoPackets
        }

        guard awaitingFirstPresentedFrame, firstPresentedFrameWaitStartTime > 0 else { return false }
        let firstFrameWait = now - firstPresentedFrameWaitStartTime
        return firstFrameWait >= Self.freezeTimeout
    }

    private func maybeLogDeferredDecodeErrorRecovery(now: CFAbsoluteTime) {
        guard now - lastDecodeErrorLogTime >= Self.decodeErrorLogInterval else { return }
        lastDecodeErrorLogTime = now
        MirageLogger.client(
            "Decode error threshold observed for stream \(streamID), deferring recovery until sustained presentation freeze"
        )
    }

    private func trimDecodeRecoveryEscalationWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.decodeRecoveryEscalationWindow
        decodeRecoveryEscalationTimestamps.removeAll { $0 < oldestAllowed }
    }

    private func requestSoftRecovery(reason: RecoveryReason) async {
        let now = currentTime()
        if !Self.shouldDispatchRecovery(
            lastDispatchTime: lastSoftRecoveryRequestTime,
            now: now,
            minimumInterval: Self.softRecoveryMinimumInterval
        ) {
            let lastTime = lastSoftRecoveryRequestTime
            let remainingMs = Int(
                ((Self.softRecoveryMinimumInterval - (now - lastTime)) * 1000)
                    .rounded(.up)
            )
            MirageLogger
                .client(
                    "Soft recovery throttled (\(reason.logLabel), \(max(0, remainingMs))ms remaining) for stream \(streamID)"
                )
            if presentationTier == .activeLive {
                startKeyframeRecoveryLoopIfNeeded()
            }
            return
        }
        lastSoftRecoveryRequestTime = now

        MirageLogger.client("Starting soft stream recovery (\(reason.logLabel)) for stream \(streamID)")
        await clearResizeState()
        clearQueuedFramesForRecovery()
        reassembler.enterKeyframeOnlyMode()
        if presentationTier == .activeLive {
            startKeyframeRecoveryLoopIfNeeded()
        }
        await requestKeyframeRecovery(reason: reason)
    }

    private func trimOverloadWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.overloadWindow
        queueDropTimestamps.removeAll { $0 < oldestAllowed }
        recoveryRequestTimestamps.removeAll { $0 < oldestAllowed }
        decodeThresholdTimestamps.removeAll { $0 < oldestAllowed }
    }

    private func maybeSignalAdaptiveFallback(now: CFAbsoluteTime) {
        if lastAdaptiveFallbackSignalTime > 0,
           now - lastAdaptiveFallbackSignalTime < Self.adaptiveFallbackCooldown {
            return
        }
        let queueOverload = queueDropTimestamps.count >= Self.overloadQueueDropThreshold &&
            recoveryRequestTimestamps.count >= Self.overloadRecoveryThreshold
        let decodeStorm = decodeThresholdTimestamps.count >= Self.decodeStormThreshold
        guard queueOverload || decodeStorm else {
            return
        }
        lastAdaptiveFallbackSignalTime = now
        MirageLogger
            .client(
                "Adaptive fallback trigger: queueDrops=\(queueDropTimestamps.count), " +
                    "recoveryRequests=\(recoveryRequestTimestamps.count), " +
                    "decodeThresholds=\(decodeThresholdTimestamps.count), stream=\(streamID)"
            )
        Task { @MainActor [weak self] in
            await self?.onAdaptiveFallbackNeeded?()
        }
    }

    func startKeyframeRecoveryLoopIfNeeded() {
        guard presentationTier == .activeLive else { return }
        guard keyframeRecoveryTask == nil else { return }
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
        keyframeRecoveryTask = Task { [weak self] in
            await self?.runKeyframeRecoveryLoop()
        }
    }

    func stopKeyframeRecoveryLoop() {
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        keyframeRecoveryAttempt = 0
        lastRecoveryRequestTime = 0
    }

    private func runKeyframeRecoveryLoop() async {
        defer {
            keyframeRecoveryTask = nil
            keyframeRecoveryAttempt = 0
            lastRecoveryRequestTime = 0
        }

        while !Task.isCancelled {
            guard presentationTier == .activeLive else { return }

            let retryDelay: Duration = switch keyframeRecoveryAttempt {
            case 0:
                Self.keyframeRecoveryInitialInterval
            case 1:
                Self.keyframeRecoverySecondaryInterval
            default:
                Self.keyframeRecoverySteadyInterval
            }
            do {
                try await Task.sleep(for: retryDelay)
            } catch {
                break
            }

            let now = currentTime()
            guard presentationTier == .activeLive else { return }
            guard let awaitingDuration = reassembler.awaitingKeyframeDuration(now: now) else { break }
            let timeout = reassembler.keyframeTimeoutSeconds()
            let initialRetryDelay = min(timeout, 0.25)
            guard awaitingDuration >= initialRetryDelay else { continue }

            if lastRecoveryRequestTime > 0,
               now - lastRecoveryRequestTime < Self.keyframeRecoveryRetryInterval {
                continue
            }

            if keyframeRecoveryAttempt >= Self.activeRecoveryMaxKeyframeAttempts {
                MirageLogger.client(
                    "Keyframe recovery retries exhausted for active stream \(streamID); escalating to hard recovery"
                )
                await requestRecovery(reason: .keyframeRecoveryLoop, restartRecoveryLoop: false)
                return
            }

            lastRecoveryRequestTime = now
            keyframeRecoveryAttempt &+= 1
            await requestKeyframeRecovery(reason: .keyframeRecoveryLoop)
        }
    }

    private func startFreezeMonitorIfNeeded() {
        guard freezeMonitorTask == nil else { return }
        freezeMonitorTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.freezeCheckInterval)
                } catch {
                    break
                }
                await evaluateFreezeState()
            }
            await clearFreezeMonitorTask()
        }
    }

    func stopFreezeMonitor() {
        freezeMonitorTask?.cancel()
        freezeMonitorTask = nil
    }

    private func clearFreezeMonitorTask() {
        freezeMonitorTask = nil
    }

    private func evaluateFreezeState() async {
        guard presentationTier == .activeLive else {
            lastPresentedProgressTime = currentTime()
            consecutiveFreezeRecoveries = 0
            return
        }
        guard lastDecodedFrameTime > 0 else { return }
        let now = currentTime()
        guard await isApplicationActiveForFreezeMonitoring() else {
            lastPresentedProgressTime = now
            consecutiveFreezeRecoveries = 0
            return
        }
        let presentationSnapshot = MirageFrameCache.shared.presentationSnapshot(for: streamID)
        if presentationSnapshot.sequence > lastPresentedSequenceObserved {
            lastPresentedSequenceObserved = presentationSnapshot.sequence
            lastPresentedProgressTime = now
            consecutiveFreezeRecoveries = 0
            return
        }

        if lastPresentedProgressTime == 0 {
            lastPresentedProgressTime = presentationSnapshot.presentedTime > 0 ? presentationSnapshot.presentedTime : now
            return
        }

        let pendingDepth = MirageFrameCache.shared.queueDepth(for: streamID)
        let lastPacketTime = reassembler.latestPacketReceivedTime()
        let hasRecentVideoPacket = lastPacketTime > 0 && now - lastPacketTime <= Self.freezeTimeout
        let packetStarved = lastPacketTime == 0 || !hasRecentVideoPacket
        let stalledPresentation = now - lastPresentedProgressTime > Self.freezeTimeout
        let isFrozen = stalledPresentation && (pendingDepth > 0 || hasRecentVideoPacket || packetStarved)
        let keyframeStarved = reassembler.isAwaitingKeyframe()
        if isFrozen {
            await maybeTriggerFreezeRecovery(
                now: now,
                keyframeStarved: keyframeStarved,
                packetStarved: packetStarved
            )
        }
        else {
            consecutiveFreezeRecoveries = 0
        }
    }

    private func isApplicationActiveForFreezeMonitoring() async -> Bool {
        #if canImport(UIKit)
        return await MainActor.run {
            UIApplication.shared.applicationState == .active
        }
        #elseif canImport(AppKit)
        return await MainActor.run {
            NSApp?.isActive ?? true
        }
        #else
        true
        #endif
    }

    private func maybeTriggerFreezeRecovery(
        now: CFAbsoluteTime,
        keyframeStarved: Bool,
        packetStarved: Bool
    ) async {
        if lastFreezeRecoveryTime > 0,
           now - lastFreezeRecoveryTime < Self.freezeRecoveryCooldown {
            return
        }
        lastFreezeRecoveryTime = now
        consecutiveFreezeRecoveries &+= 1
        Task { @MainActor [weak self] in
            await self?.onStallEvent?()
        }

        switch Self.freezeRecoveryDecision(
            keyframeStarved: keyframeStarved,
            packetStarved: packetStarved,
            consecutiveFreezeRecoveries: consecutiveFreezeRecoveries
        ) {
        case let .monitor(kind):
            let attempt = consecutiveFreezeRecoveries
            consecutiveFreezeRecoveries = 0
            MirageLogger.client(
                "Presentation stall detected (attempt \(attempt)) for stream \(streamID); " +
                    "\(kind.rawValue), monitoring only"
            )
            return
        case let .hard(kind):
            let attempt = consecutiveFreezeRecoveries
            consecutiveFreezeRecoveries = 0
            MirageLogger.client(
                "Presentation stall persisted (\(kind.rawValue), attempt \(attempt)) for stream \(streamID); " +
                    "escalating to hard recovery"
            )
            await requestRecovery(reason: .freezeTimeout)
            return
        case let .soft(kind):
            MirageLogger.client(
                "Presentation stall detected (\(kind.rawValue), attempt \(consecutiveFreezeRecoveries)) for stream \(streamID); " +
                    "requesting bounded recovery"
            )
            await requestSoftRecovery(reason: .freezeTimeout)
        }
    }

    func setResizeState(_ newState: ResizeState) async {
        guard resizeState != newState else { return }
        resizeState = newState

        Task { @MainActor [weak self] in
            guard let self else { return }
            await onResizeStateChanged?(newState)
        }
    }

    func processResizeEvent(
        pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    )
    async {
        // Calculate aspect ratio
        let aspectRatio = pixelSize.width / pixelSize.height

        // Calculate relative scale
        let drawablePointSize = CGSize(
            width: pixelSize.width / scaleFactor,
            height: pixelSize.height / scaleFactor
        )
        let drawableArea = drawablePointSize.width * drawablePointSize.height
        let screenArea = screenBounds.width * screenBounds.height
        let relativeScale = min(1.0, drawableArea / screenArea)

        // Skip initial layout (prevents decoder P-frame discard mode on first draw)
        let isInitialLayout = lastSentAspectRatio == 0 && lastSentRelativeScale == 0 && lastSentPixelSize == .zero
        if isInitialLayout {
            lastSentAspectRatio = aspectRatio
            lastSentRelativeScale = relativeScale
            lastSentPixelSize = pixelSize
            await setResizeState(.idle)
            return
        }

        // Check if changed significantly
        let aspectChanged = abs(aspectRatio - lastSentAspectRatio) > 0.01
        let scaleChanged = abs(relativeScale - lastSentRelativeScale) > 0.01
        let pixelChanged = pixelSize != lastSentPixelSize
        guard aspectChanged || scaleChanged || pixelChanged else {
            await setResizeState(.idle)
            return
        }

        // Update last sent values
        lastSentAspectRatio = aspectRatio
        lastSentRelativeScale = relativeScale
        lastSentPixelSize = pixelSize

        let event = ResizeEvent(
            aspectRatio: aspectRatio,
            relativeScale: relativeScale,
            clientScreenSize: screenBounds,
            pixelWidth: Int(pixelSize.width.rounded()),
            pixelHeight: Int(pixelSize.height.rounded())
        )

        Task { @MainActor [weak self] in
            await self?.onResizeEvent?(event)
        }

        // Fallback timeout
        do {
            try await Task.sleep(for: Self.resizeTimeout)
            if case .awaiting = resizeState { await setResizeState(.idle) }
        } catch {
            // Cancelled, ignore
        }
    }
}
