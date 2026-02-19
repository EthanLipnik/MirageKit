//
//  StreamContext+Streaming+Starts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Standard stream startup paths.
//

import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func start(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let window = windowWrapper.window
        let application = applicationWrapper.application
        let display = displayWrapper.display

        onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onEncodedFrame: onEncodedFrame
        )
        self.packetSender = packetSender
        await packetSender.start()
        await packetSender.setTargetBitrateBps(encoderConfig.bitrate)

        let captureTarget = streamTargetDimensions(windowFrame: window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = window.frame
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Stream init")
        MirageLogger
            .stream(
                "Stream init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)"
            )
        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder
        try await encoder.createSession(width: Int(outputSize.width), height: Int(outputSize.height))
        activePixelFormat = await encoder.getActivePixelFormat()

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
                    logPrefix: "Frame",
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
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: false
        )
        self.captureEngine = captureEngine
        let frameInbox = self.frameInbox
        await captureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot()
            let pendingPressure = snapshot.pending >= max(1, snapshot.capacity - 1)
            let backpressure = self?.backpressureActiveSnapshot ?? false
            guard pendingPressure || backpressure else { return false }

            // Keep the drain loop alive while we are dropping early so stall recovery
            // and backpressure re-checks can run even when no new frames are enqueued.
            if frameInbox.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }

        try await captureEngine.startCapture(
            window: window,
            application: application,
            display: display,
            outputScale: streamScale,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger.stream("Started stream \(streamID) for window \(windowID)")
    }

    func startLoginDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        showsCursor: Bool = true,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let display = displayWrapper.display

        onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onEncodedFrame: onEncodedFrame
        )
        self.packetSender = packetSender
        await packetSender.start()
        await packetSender.setTargetBitrateBps(encoderConfig.bitrate)

        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        baseCaptureSize = captureResolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        await applyDerivedQuality(for: outputSize, logLabel: "Display init")
        MirageLogger
            .stream(
                "Display init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(width)x\(height), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)"
            )
        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder
        try await encoder.createSession(width: width, height: height)

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
                    logPrefix: "Login frame",
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
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: CGVirtualDisplayBridge.isMirageDisplay(display.displayID)
        )
        self.captureEngine = captureEngine
        let frameInbox = self.frameInbox
        await captureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot()
            let pendingPressure = snapshot.pending >= max(1, snapshot.capacity - 1)
            let backpressure = self?.backpressureActiveSnapshot ?? false
            guard pendingPressure || backpressure else { return false }

            // Keep the drain loop alive while we are dropping early so stall recovery
            // and backpressure re-checks can run even when no new frames are enqueued.
            if frameInbox.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }

        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: outputSize,
            showsCursor: showsCursor,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger.stream("Started login display stream \(streamID) at \(width)x\(height)")
    }

    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        excludedWindows: [SCWindowWrapper] = [],
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    )
    async throws {
        guard !isRunning else { return }
        isRunning = true
        captureFrameRateOverride = currentFrameRate
        captureFrameRate = currentFrameRate

        let display = displayWrapper.display

        onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(
            maxPayloadSize: maxPayloadSize,
            mediaSecurityContext: mediaSecurityContext,
            onEncodedFrame: onEncodedFrame
        )
        self.packetSender = packetSender
        await packetSender.start()
        await packetSender.setTargetBitrateBps(encoderConfig.bitrate)

        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder

        let captureResolution = resolution ?? CGSize(width: display.width, height: display.height)
        baseCaptureSize = captureResolution
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Desktop init")
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger
            .stream(
                "Desktop encoding at \(width)x\(height) (latency=\(latencyMode.displayName), scale=\(streamScale), queue=\(maxQueuedBytes / 1024)KB)"
            )
        try await encoder.createSession(width: width, height: height)

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
                    logPrefix: "Desktop frame",
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
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: CGVirtualDisplayBridge.isMirageDisplay(display.displayID)
        )
        self.captureEngine = captureEngine
        let frameInbox = self.frameInbox
        await captureEngine.setAdmissionDropper { [weak self] in
            let snapshot = frameInbox.pendingSnapshot()
            let pendingPressure = snapshot.pending >= max(1, snapshot.capacity - 1)
            let backpressure = self?.backpressureActiveSnapshot ?? false
            guard pendingPressure || backpressure else { return false }

            // Keep the drain loop alive while we are dropping early so stall recovery
            // and backpressure re-checks can run even when no new frames are enqueued.
            if frameInbox.scheduleIfNeeded() {
                Task(priority: .userInitiated) { await self?.processPendingFrames() }
            }
            return true
        }

        let resolvedExcludedWindows = excludedWindows.map(\.window)
        let captureSizeForSCK = CGVirtualDisplayBridge.isMirageDisplay(display.displayID) ? outputSize : nil
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureSizeForSCK,
            excludedWindows: resolvedExcludedWindows,
            showsCursor: false,
            onFrame: { [weak self] frame in
                self?.enqueueCapturedFrame(frame)
            },
            onAudio: onCapturedAudioBuffer
        )
        await refreshCaptureCadence()

        MirageLogger.stream("Started desktop display stream \(streamID) at \(width)x\(height)")
    }
}

#endif
