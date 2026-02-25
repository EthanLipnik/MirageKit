//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display streaming paths.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    private struct VirtualDisplayPlacement: Sendable {
        let snapshot: SharedVirtualDisplayManager.DisplaySnapshot
        let visibleBounds: CGRect
        let captureSourceRect: CGRect
        let visiblePixelResolution: CGSize
        let insetsPixels: CGSize
    }

    func startWithVirtualDisplay(
        windowWrapper _: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientDisplayResolution: CGSize,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void,
        onVirtualDisplayReady: @escaping @Sendable (SharedVirtualDisplayManager.DisplaySnapshot, CGRect) async -> Void = {
            _, _ in
        }
    )
        async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true
        // Keep the virtual display at the target refresh so capture stays aligned.
        let virtualDisplayRefreshRate = SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate)
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let application = applicationWrapper.application
        applicationProcessID = application.processID

        onEncodedPacket = onEncodedFrame
        self.onContentBoundsChanged = onContentBoundsChanged
        self.onNewWindowDetected = onNewWindowDetected
        let packetSender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onEncodedFrame: onEncodedFrame
        )
        self.packetSender = packetSender
        await packetSender.start()
        await packetSender.setTargetBitrateBps(encoderConfig.bitrate)

        MirageLogger
            .stream(
                "Starting stream \(streamID) with dedicated virtual display at \(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height))"
            )

        let placement = try await configureDedicatedVirtualDisplay(
            requestedVisibleResolution: clientDisplayResolution,
            refreshRate: virtualDisplayRefreshRate,
            isUpdate: false
        )
        let vdContext = placement.snapshot
        virtualDisplayContext = vdContext

        await onVirtualDisplayReady(vdContext, placement.visibleBounds)

        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdContext.spaceID,
            displayID: vdContext.displayID,
            displayBounds: placement.visibleBounds
        )

        let resolvedDisplayWrapper = try await resolveVirtualDisplayDisplay(
            displayID: vdContext.displayID,
            label: "virtual display start"
        )

        let resolvedDisplayID = resolvedDisplayWrapper.display.displayID
        if !CGVirtualDisplayBridge.isMirageDisplay(resolvedDisplayID) {
            MirageLogger.error(.stream, "Expected virtual display capture, got display \(resolvedDisplayID)")
        }
        MirageLogger
            .stream(
                "Resolved display capture target \(resolvedDisplayID) sourceRect=\(placement.captureSourceRect)"
            )

        baseCaptureSize = sanitizePixelResolution(clientDisplayResolution)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        lastWindowFrame = placement.visibleBounds
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Virtual display init")
        MirageLogger
            .stream(
                "Virtual display init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
            )
        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            performanceMode: performanceMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger
            .encoder(
                "Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (visible target \(Int(baseCaptureSize.width))x\(Int(baseCaptureSize.height)))"
            )

        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        let streamID = streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
                guard let self else { return }

                let contentRect = currentContentRect
                let frameNum = localFrameNumber
                let seqStart = localSequenceNumber

                let now = CFAbsoluteTimeGetCurrent()
                let fecBlockSize = resolvedFECBlockSize(isKeyframe: isKeyframe, now: now)
                let frameByteCount = encodedData.count
                let dataFragments = (frameByteCount + maxPayloadSize - 1) / maxPayloadSize
                let parityFragments = fecBlockSize > 1 ? (dataFragments + fecBlockSize - 1) / fecBlockSize : 0
                let totalFragments = dataFragments + parityFragments
                let wireBytes = frameByteCount + parityFragments * maxPayloadSize
                localSequenceNumber += UInt32(totalFragments)
                localFrameNumber += 1

                let flags = baseFrameFlags.union(dynamicFrameFlags)
                let dimToken = dimensionToken
                let epoch = epoch

                let generation = packetSender.currentGenerationSnapshot()
                if isKeyframe {
                    Task(priority: .userInitiated) {
                        await self.markKeyframeInFlight()
                        await self.markKeyframeSent()
                    }
                }
                let workItem = StreamPacketSender.WorkItem(
                    encodedData: encodedData,
                    frameByteCount: frameByteCount,
                    isKeyframe: isKeyframe,
                    presentationTime: presentationTime,
                    contentRect: contentRect,
                    streamID: streamID,
                    frameNumber: frameNum,
                    sequenceNumberStart: seqStart,
                    additionalFlags: flags,
                    dimensionToken: dimToken,
                    epoch: epoch,
                    fecBlockSize: fecBlockSize,
                    wireBytes: wireBytes,
                    logPrefix: "VD Frame",
                    generation: generation,
                    onSendStart: nil,
                    onSendComplete: nil
                )
                packetSender.enqueue(workItem)
            }, onFrameComplete: { [weak self] in
                Task(priority: .userInitiated) { await self?.finishEncoding() }
            }
        )

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: resolvedPixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: true
        )
        captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startDisplayCapture(
            display: resolvedDisplayWrapper.display,
            resolution: outputSize,
            sourceRect: placement.captureSourceRect,
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger
            .stream("Started stream \(streamID) with virtual display \(vdContext.displayID) for window \(windowID)")
    }

    func updateVirtualDisplayResolution(newResolution: CGSize) async throws {
        guard isRunning, useVirtualDisplay else { return }
        let requestedPixels = sanitizePixelResolution(newResolution)

        // Client drawable/layout updates can produce repeated display-size notifications with
        // effectively unchanged visible resolution. Reconfiguring the dedicated virtual display
        // in that case can introduce avoidable capture restarts and transient blank frames.
        if baseCaptureSize != .zero, isResolutionMatch(baseCaptureSize, requestedPixels, tolerance: 4.0) {
            MirageLogger
                .stream(
                    "Skipping dedicated virtual display update for stream \(streamID): visible size unchanged (\(Int(baseCaptureSize.width))x\(Int(baseCaptureSize.height)))"
                )
            return
        }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "virtual display resize")
        resetPipelineStateForReconfiguration(reason: "virtual display resize")

        MirageLogger
            .stream(
                "Updating dedicated virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)"
            )

        await captureEngine?.stopCapture()

        let placement = try await configureDedicatedVirtualDisplay(
            requestedVisibleResolution: requestedPixels,
            refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate),
            isUpdate: true
        )
        let newContext = placement.snapshot
        virtualDisplayContext = newContext

        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: newContext.spaceID,
            displayID: newContext.displayID,
            displayBounds: placement.visibleBounds
        )

        let resolvedDisplayWrapper = try await resolveVirtualDisplayDisplay(
            displayID: newContext.displayID,
            label: "virtual display update"
        )

        baseCaptureSize = requestedPixels
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        lastWindowFrame = placement.visibleBounds
        updateQueueLimits()
        if let encoder {
            try await encoder.updateDimensions(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            let resolvedPixelFormat = await encoder.getActivePixelFormat()
            activePixelFormat = resolvedPixelFormat
            MirageLogger
                .encoder("Encoder updated to \(Int(outputSize.width))x\(Int(outputSize.height)) for resolution change")
        }

        await applyDerivedQuality(for: outputSize, logLabel: "Virtual display resize")

        let captureConfig = encoderConfig.withInternalOverrides(pixelFormat: activePixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: true
        )
        captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startDisplayCapture(
            display: resolvedDisplayWrapper.display,
            resolution: outputSize,
            sourceRect: placement.captureSourceRect,
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        await encoder?.forceKeyframe()

        MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
    }

    private func resolveVirtualDisplayDisplay(
        displayID: CGDirectDisplayID,
        label: String,
        maxAttempts: Int = 8,
        initialDelayMs: Int = 80
    )
    async throws -> SCDisplayWrapper {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                if let display = content.displays.first(where: { $0.displayID == displayID }) {
                    if attempt > 1 {
                        MirageLogger.stream("Resolved virtual display \(displayID) on attempt \(attempt) (\(label))")
                    }
                    return SCDisplayWrapper(display: display)
                }

                if attempt < attempts {
                    MirageLogger
                        .stream(
                            "Virtual display \(displayID) not yet in SCShareableContent on attempt \(attempt)/\(attempts) (\(label)); retrying in \(delayMs)ms"
                        )
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(1000, Int(Double(delayMs) * 1.6))
                }
            } catch {
                if attempt >= attempts { throw error }
                MirageLogger.error(
                    .stream,
                    "Failed to query SCShareableContent for display \(displayID) (\(label)) attempt \(attempt)/\(attempts): \(error)"
                )
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(1000, Int(Double(delayMs) * 1.6))
            }
        }

        throw MirageError.protocolError("Unable to resolve virtual display \(displayID) for stream \(streamID) (\(label))")
    }

    private func configureDedicatedVirtualDisplay(
        requestedVisibleResolution: CGSize,
        refreshRate: Int,
        isUpdate: Bool
    )
    async throws -> VirtualDisplayPlacement {
        let requestedPixels = sanitizePixelResolution(requestedVisibleResolution)
        var snapshot: SharedVirtualDisplayManager.DisplaySnapshot
        if isUpdate {
            snapshot = try await SharedVirtualDisplayManager.shared.updateDedicatedDisplay(
                for: streamID,
                newResolution: requestedPixels,
                refreshRate: refreshRate
            )
        } else {
            snapshot = try await SharedVirtualDisplayManager.shared.acquireDedicatedDisplay(
                for: streamID,
                resolution: requestedPixels,
                refreshRate: refreshRate,
                colorSpace: encoderConfig.colorSpace
            )
        }

        var placement = await resolveVirtualDisplayPlacement(from: snapshot)
        MirageLogger.stream(
            "Virtual display calibration (initial) stream \(streamID): requested=\(Int(requestedPixels.width))x\(Int(requestedPixels.height)), display=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height)), scale=\(placement.snapshot.scaleFactor)"
        )
        if isResolutionMatch(placement.visiblePixelResolution, requestedPixels) {
            return placement
        }

        let expandedResolution = sanitizePixelResolution(
            CGSize(
                width: requestedPixels.width + placement.insetsPixels.width,
                height: requestedPixels.height + placement.insetsPixels.height
            )
        )
        if !isResolutionMatch(expandedResolution, snapshot.resolution) {
            snapshot = try await SharedVirtualDisplayManager.shared.updateDedicatedDisplay(
                for: streamID,
                newResolution: expandedResolution,
                refreshRate: refreshRate
            )
            placement = await resolveVirtualDisplayPlacement(from: snapshot)
            MirageLogger.stream(
                "Virtual display calibration (expanded) stream \(streamID): display=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), insets=\(Int(placement.insetsPixels.width))x\(Int(placement.insetsPixels.height))"
            )
        }

        let correction = CGSize(
            width: requestedPixels.width - placement.visiblePixelResolution.width,
            height: requestedPixels.height - placement.visiblePixelResolution.height
        )
        if abs(correction.width) > 1 || abs(correction.height) > 1 {
            let correctedResolution = sanitizePixelResolution(
                CGSize(
                    width: placement.snapshot.resolution.width + correction.width,
                    height: placement.snapshot.resolution.height + correction.height
                )
            )
            if !isResolutionMatch(correctedResolution, placement.snapshot.resolution) {
                snapshot = try await SharedVirtualDisplayManager.shared.updateDedicatedDisplay(
                    for: streamID,
                    newResolution: correctedResolution,
                    refreshRate: refreshRate
                )
                placement = await resolveVirtualDisplayPlacement(from: snapshot)
                MirageLogger.stream(
                    "Virtual display calibration (corrected) stream \(streamID): display=\(Int(placement.snapshot.resolution.width))x\(Int(placement.snapshot.resolution.height)), visible=\(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)), correction=\(Int(correction.width))x\(Int(correction.height))"
                )
            }
        }

        if !isResolutionMatch(placement.visiblePixelResolution, requestedPixels) {
            MirageLogger
                .stream(
                    "Virtual display visible size \(Int(placement.visiblePixelResolution.width))x\(Int(placement.visiblePixelResolution.height)) differs from requested \(Int(requestedPixels.width))x\(Int(requestedPixels.height)) after calibration"
                )
        }

        return placement
    }

    private func resolveVirtualDisplayPlacement(
        from snapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        maxAttempts: Int = 8,
        initialDelayMs: Int = 60
    )
    async -> VirtualDisplayPlacement {
        let attempts = max(1, maxAttempts)
        var delayMs = max(20, initialDelayMs)
        var lastPlacement = computeVirtualDisplayPlacement(from: snapshot)

        for attempt in 1 ... attempts {
            lastPlacement = computeVirtualDisplayPlacement(from: snapshot)
            if CGVirtualDisplayBridge.hasScreen(snapshot.displayID) || attempt == attempts {
                return lastPlacement
            }
            try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
            delayMs = min(400, Int(Double(delayMs) * 1.4))
        }

        return lastPlacement
    }

    private func computeVirtualDisplayPlacement(
        from snapshot: SharedVirtualDisplayManager.DisplaySnapshot
    )
    -> VirtualDisplayPlacement {
        let scaleFactor = max(1.0, snapshot.scaleFactor)
        let logicalResolution = SharedVirtualDisplayManager.logicalResolution(
            for: snapshot.resolution,
            scaleFactor: scaleFactor
        )
        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            snapshot.displayID,
            knownResolution: logicalResolution
        )
        var visibleBounds = CGVirtualDisplayBridge.getDisplayVisibleBounds(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        visibleBounds = visibleBounds.intersection(displayBounds)
        if visibleBounds.isEmpty {
            visibleBounds = displayBounds
        }

        var captureSourceRect = CGVirtualDisplayBridge.displayCaptureSourceRect(
            snapshot.displayID,
            knownBounds: displayBounds
        )
        if captureSourceRect.isEmpty {
            let localX = visibleBounds.minX - displayBounds.minX
            let localY = visibleBounds.minY - displayBounds.minY
            captureSourceRect = CGRect(
                x: max(0, localX),
                y: max(0, localY),
                width: visibleBounds.width,
                height: visibleBounds.height
            )
        }

        let insets = CGVirtualDisplayBridge.displayInsets(
            displayBounds: displayBounds,
            visibleBounds: visibleBounds
        )
        let insetsPixels = CGSize(
            width: ceil(insets.horizontal * scaleFactor),
            height: ceil(insets.vertical * scaleFactor)
        )
        let visiblePixelResolution = sanitizePixelResolution(
            CGSize(
                width: visibleBounds.width * scaleFactor,
                height: visibleBounds.height * scaleFactor
            )
        )

        return VirtualDisplayPlacement(
            snapshot: snapshot,
            visibleBounds: visibleBounds,
            captureSourceRect: captureSourceRect,
            visiblePixelResolution: visiblePixelResolution,
            insetsPixels: insetsPixels
        )
    }

    private func sanitizePixelResolution(_ resolution: CGSize) -> CGSize {
        CGSize(
            width: max(1, ceil(resolution.width)),
            height: max(1, ceil(resolution.height))
        )
    }

    private func isResolutionMatch(_ lhs: CGSize, _ rhs: CGSize, tolerance: CGFloat = 1.0) -> Bool {
        abs(lhs.width - rhs.width) <= tolerance &&
            abs(lhs.height - rhs.height) <= tolerance
    }
}

#endif
