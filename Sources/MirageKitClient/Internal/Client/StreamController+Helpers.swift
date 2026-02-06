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
        if isInputBlocked { updateInputBlocking(false) }
    }

    /// Update input blocking state and notify callback
    func updateInputBlocking(_ isBlocked: Bool) {
        guard isInputBlocked != isBlocked else { return }
        isInputBlocked = isBlocked
        MirageLogger.client("Input blocking state changed: \(isBlocked ? "BLOCKED" : "allowed") for stream \(streamID)")
        Task { @MainActor [weak self] in
            await self?.onInputBlockingChanged?(isBlocked)
        }
    }

    func recordQueueDrop() {
        queueDropsSinceLastLog += 1
        metricsTracker.recordQueueDrop()
        let now = CFAbsoluteTimeGetCurrent()
        queueDropTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
    }

    func maybeTriggerBackpressureRecovery() {
        let now = CFAbsoluteTimeGetCurrent()
        if lastBackpressureRecoveryTime > 0,
           now - lastBackpressureRecoveryTime < Self.backpressureRecoveryCooldown {
            return
        }
        lastBackpressureRecoveryTime = now
        reassembler.enterKeyframeOnlyMode()
        Task { [weak self] in
            guard let self else { return }
            await self.startKeyframeRecoveryLoopIfNeeded()
            await self.requestKeyframeRecovery(reason: "decode-backpressure")
        }
    }

    func requestKeyframeRecovery(reason: String) async {
        let now = CFAbsoluteTimeGetCurrent()
        recoveryRequestTimestamps.append(now)
        trimOverloadWindow(now: now)
        maybeSignalAdaptiveFallback(now: now)
        guard let handler = onKeyframeNeeded else { return }
        MirageLogger.client("Requesting recovery keyframe (\(reason)) for stream \(streamID)")
        await MainActor.run {
            handler()
        }
    }

    private func trimOverloadWindow(now: CFAbsoluteTime) {
        let oldestAllowed = now - Self.overloadWindow
        queueDropTimestamps.removeAll { $0 < oldestAllowed }
        recoveryRequestTimestamps.removeAll { $0 < oldestAllowed }
    }

    private func maybeSignalAdaptiveFallback(now: CFAbsoluteTime) {
        if lastAdaptiveFallbackSignalTime > 0,
           now - lastAdaptiveFallbackSignalTime < Self.adaptiveFallbackCooldown {
            return
        }
        guard queueDropTimestamps.count >= Self.overloadQueueDropThreshold,
              recoveryRequestTimestamps.count >= Self.overloadRecoveryThreshold else {
            return
        }
        lastAdaptiveFallbackSignalTime = now
        MirageLogger
            .client(
                "Adaptive fallback trigger: queueDrops=\(queueDropTimestamps.count), " +
                    "recoveryRequests=\(recoveryRequestTimestamps.count), stream=\(streamID)"
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
            if lastRecoveryRequestTime > 0, now - lastRecoveryRequestTime < timeout { continue }
            lastRecoveryRequestTime = now
            await requestKeyframeRecovery(reason: "keyframe-recovery-loop")
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

    private func evaluateFreezeState() {
        guard lastDecodedFrameTime > 0 else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let isFrozen = now - lastDecodedFrameTime > Self.freezeTimeout
        updateInputBlocking(isFrozen)
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
