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
    // MARK: - Private Helpers

    func markFirstFrameReceived() {
        guard !hasReceivedFirstFrame else { return }
        hasReceivedFirstFrame = true
        Task { @MainActor [weak self] in
            await self?.onFirstFrame?()
        }
    }

    func recordDecodedFrame() {
        lastDecodedFrameTime = CFAbsoluteTimeGetCurrent()
        startFreezeMonitorIfNeeded()
    }

    func recordQueueDrop() {
        queueDropsSinceLastLog += 1
        metricsTracker.recordQueueDrop()
        let now = CFAbsoluteTimeGetCurrent()
        queueDropTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
    }

    func recordDecodeThresholdEvent() {
        let now = CFAbsoluteTimeGetCurrent()
        decodeThresholdTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
    }

    func maybeTriggerBackpressureRecovery(queueDepth: Int) {
        let now = CFAbsoluteTimeGetCurrent()
        let recentDropCount = queueDropTimestamps.reduce(into: 0) { count, timestamp in
            if now - timestamp <= Self.backpressureRecoveryWindow {
                count += 1
            }
        }
        guard recentDropCount >= Self.backpressureRecoveryDropThreshold else { return }
        if lastBackpressureRecoveryTime > 0,
           now - lastBackpressureRecoveryTime < Self.backpressureRecoveryCooldown {
            return
        }
        lastBackpressureRecoveryTime = now
        Task { [weak self] in
            guard let self else { return }
            await self.requestRecovery(reason: .decodeBackpressure(queueDepth: queueDepth))
        }
    }

    func requestKeyframeRecovery(reason: RecoveryReason) async {
        let now = CFAbsoluteTimeGetCurrent()
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
        guard keyframeRecoveryTask == nil else { return }
        keyframeRecoveryTask = Task { [weak self] in
            await self?.runKeyframeRecoveryLoop()
        }
    }

    private func runKeyframeRecoveryLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.keyframeRecoveryInterval)
            } catch {
                break
            }
            let now = CFAbsoluteTimeGetCurrent()
            guard let awaitingDuration = reassembler.awaitingKeyframeDuration(now: now) else { break }
            let timeout = reassembler.keyframeTimeoutSeconds()
            guard awaitingDuration >= timeout else { continue }
            let retryInterval = min(timeout, Self.keyframeRecoveryRetryInterval)
            if lastRecoveryRequestTime > 0, now - lastRecoveryRequestTime < retryInterval { continue }
            lastRecoveryRequestTime = now
            await requestKeyframeRecovery(reason: .keyframeRecoveryLoop)
        }
        keyframeRecoveryTask = nil
        lastRecoveryRequestTime = 0
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
        guard lastDecodedFrameTime > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
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
        let stalledPresentation = now - lastPresentedProgressTime > Self.freezeTimeout
        let isFrozen = stalledPresentation && (pendingDepth > 0 || hasRecentVideoPacket)
        if isFrozen { maybeTriggerFreezeRecovery(now: now) }
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

    private func maybeTriggerFreezeRecovery(now: CFAbsoluteTime) {
        if lastFreezeRecoveryTime > 0,
           now - lastFreezeRecoveryTime < Self.freezeRecoveryCooldown {
            return
        }
        lastFreezeRecoveryTime = now
        consecutiveFreezeRecoveries &+= 1

        let reason: RecoveryReason = .freezeTimeout
        if consecutiveFreezeRecoveries >= Self.freezeRecoveryEscalationThreshold {
            MirageLogger.client(
                "Freeze recovery escalated to full reset after \(consecutiveFreezeRecoveries) attempts for stream \(streamID)"
            )
            Task { [weak self] in
                guard let self else { return }
                await self.requestRecovery(reason: reason)
            }
            return
        }

        MirageLogger.client("Freeze recovery requesting keyframe for stream \(streamID)")
        Task { [weak self] in
            guard let self else { return }
            await self.requestKeyframeRecovery(reason: reason)
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
