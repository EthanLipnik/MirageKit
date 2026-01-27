//
//  StreamController+Helpers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Stream controller extensions.
//

import Foundation
import CoreGraphics

extension StreamController {
    // MARK: - Private Helpers

    func markFirstFrameReceived() {
        guard !hasReceivedFirstFrame else { return }
        hasReceivedFirstFrame = true
        Task { @MainActor [weak self] in
            await self?.onFirstFrame?()
        }
    }

    /// Update input blocking state and notify callback
    func updateInputBlocking(_ isBlocked: Bool) {
        guard self.isInputBlocked != isBlocked else { return }
        self.isInputBlocked = isBlocked
        MirageLogger.client("Input blocking state changed: \(isBlocked ? "BLOCKED" : "allowed") for stream \(streamID)")
        if isBlocked {
            startKeyframeRecoveryLoop()
        } else {
            stopKeyframeRecoveryLoop()
        }
        Task { @MainActor [weak self] in
            await self?.onInputBlockingChanged?(isBlocked)
        }
    }

    private func startKeyframeRecoveryLoop() {
        guard keyframeRecoveryTask == nil else { return }
        keyframeRecoveryTask = Task { [weak self] in
            await self?.runKeyframeRecoveryLoop()
        }
    }

    private func stopKeyframeRecoveryLoop() {
        keyframeRecoveryTask?.cancel()
        keyframeRecoveryTask = nil
        lastRecoveryRequestTime = 0
    }

    private func runKeyframeRecoveryLoop() async {
        while isInputBlocked && !Task.isCancelled {
            do {
                try await Task.sleep(for: Self.keyframeRecoveryInterval)
            } catch {
                break
            }
            guard isInputBlocked && !Task.isCancelled else { break }
            let now = CFAbsoluteTimeGetCurrent()
            guard let awaitingDuration = reassembler.awaitingKeyframeDuration(now: now) else { continue }
            let timeout = reassembler.keyframeTimeoutSeconds()
            guard awaitingDuration >= timeout else { continue }
            if lastRecoveryRequestTime > 0, now - lastRecoveryRequestTime < timeout {
                continue
            }
            guard let handler = onKeyframeNeeded else { break }
            lastRecoveryRequestTime = now
            await MainActor.run {
                handler()
            }
        }
        keyframeRecoveryTask = nil
    }

    func setResizeState(_ newState: ResizeState) async {
        guard resizeState != newState else { return }
        resizeState = newState

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.onResizeStateChanged?(newState)
        }
    }

    func processResizeEvent(
        pixelSize: CGSize,
        screenBounds: CGSize,
        scaleFactor: CGFloat
    ) async {
        // Calculate aspect ratio
        let aspectRatio = pixelSize.width / pixelSize.height

        // Apply 5K resolution cap while preserving aspect ratio
        var cappedSize = pixelSize
        if cappedSize.width > Self.maxResolutionWidth {
            cappedSize.width = Self.maxResolutionWidth
            cappedSize.height = cappedSize.width / aspectRatio
        }
        if cappedSize.height > Self.maxResolutionHeight {
            cappedSize.height = Self.maxResolutionHeight
            cappedSize.width = cappedSize.height * aspectRatio
        }

        // Round to even dimensions for HEVC codec
        cappedSize.width = floor(cappedSize.width / 2) * 2
        cappedSize.height = floor(cappedSize.height / 2) * 2
        let cappedPixelSize = CGSize(width: cappedSize.width, height: cappedSize.height)

        // Calculate relative scale
        let drawablePointSize = CGSize(
            width: cappedSize.width / scaleFactor,
            height: cappedSize.height / scaleFactor
        )
        let drawableArea = drawablePointSize.width * drawablePointSize.height
        let screenArea = screenBounds.width * screenBounds.height
        let relativeScale = min(1.0, drawableArea / screenArea)

        // Skip initial layout (prevents decoder P-frame discard mode on first draw)
        let isInitialLayout = lastSentAspectRatio == 0 && lastSentRelativeScale == 0 && lastSentPixelSize == .zero
        if isInitialLayout {
            lastSentAspectRatio = aspectRatio
            lastSentRelativeScale = relativeScale
            lastSentPixelSize = cappedPixelSize
            await setResizeState(.idle)
            return
        }

        // Check if changed significantly
        let aspectChanged = abs(aspectRatio - lastSentAspectRatio) > 0.01
        let scaleChanged = abs(relativeScale - lastSentRelativeScale) > 0.01
        let pixelChanged = cappedPixelSize != lastSentPixelSize
        guard aspectChanged || scaleChanged || pixelChanged else {
            await setResizeState(.idle)
            return
        }

        // Update last sent values
        lastSentAspectRatio = aspectRatio
        lastSentRelativeScale = relativeScale
        lastSentPixelSize = cappedPixelSize

        let event = ResizeEvent(
            aspectRatio: aspectRatio,
            relativeScale: relativeScale,
            clientScreenSize: screenBounds,
            pixelWidth: Int(cappedSize.width),
            pixelHeight: Int(cappedSize.height)
        )

        Task { @MainActor [weak self] in
            await self?.onResizeEvent?(event)
        }

        // Fallback timeout
        do {
            try await Task.sleep(for: Self.resizeTimeout)
            if case .awaiting = resizeState {
                await setResizeState(.idle)
            }
        } catch {
            // Cancelled, ignore
        }
    }
}
