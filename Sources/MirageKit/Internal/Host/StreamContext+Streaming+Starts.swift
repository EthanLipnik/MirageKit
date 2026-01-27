//
//  StreamContext+Streaming+Starts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Standard stream startup paths.
//

import Foundation
import CoreVideo

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func start(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true

        let window = windowWrapper.window
        let application = applicationWrapper.application
        let display = displayWrapper.display

        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder

        let captureTarget = streamTargetDimensions(windowFrame: window.frame)
        baseCaptureSize = CGSize(width: captureTarget.width, height: captureTarget.height)
        streamScale = resolvedStreamScale(
            for: baseCaptureSize,
            requestedScale: requestedStreamScale * adaptiveScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .window
        lastWindowFrame = window.frame
        updateQueueLimits()
        MirageLogger.stream("Stream init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)")
        try await encoder.createSession(width: Int(outputSize.width), height: Int(outputSize.height))
        activePixelFormat = await encoder.getActivePixelFormat()

        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
            let dimToken = self.dimensionToken
            let epoch = self.epoch

            let generation = packetSender.currentGenerationSnapshot()
            if isKeyframe {
                Task(priority: .userInitiated) {
                    await self.markKeyframeInFlight()
                    await self.markKeyframeSent()
                }
            }
            let workItem = StreamPacketSender.WorkItem(
                encodedData: encodedData,
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Frame",
                generation: generation,
                onSendStart: nil,
                onSendComplete: nil
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate
        )
        self.captureEngine = captureEngine

        try await captureEngine.startCapture(
            window: window,
            application: application,
            display: display,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        startCadenceTaskIfNeeded()

        MirageLogger.stream("Started stream \(streamID) for window \(windowID)")
    }

    func startLoginDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        showsCursor: Bool = true,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true

        let display = displayWrapper.display

        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

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
            requestedScale: requestedStreamScale * adaptiveScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream("Display init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(width)x\(height), queue=\(maxQueuedBytes / 1024)KB, buffer=\(frameBufferDepth)")
        try await encoder.createSession(width: width, height: height)

        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber

            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
            let dimToken = self.dimensionToken
            let epoch = self.epoch

            let generation = packetSender.currentGenerationSnapshot()
            if isKeyframe {
                Task(priority: .userInitiated) {
                    await self.markKeyframeInFlight()
                    await self.markKeyframeSent()
                }
            }
            let workItem = StreamPacketSender.WorkItem(
                encodedData: encodedData,
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Login frame",
                generation: generation,
                onSendStart: nil,
                onSendComplete: nil
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate
        )
        self.captureEngine = captureEngine

        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: outputSize,
            showsCursor: showsCursor
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        startCadenceTaskIfNeeded()

        MirageLogger.stream("Started login display stream \(streamID) at \(width)x\(height)")
    }

    func startDesktopDisplay(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize? = nil,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        captureFrameRateOverride = nil
        captureFrameRate = currentFrameRate
        updateFrameThrottle()

        let display = displayWrapper.display

        self.onEncodedPacket = onEncodedFrame
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

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
            requestedScale: requestedStreamScale * adaptiveScale,
            logLabel: "Resolution cap"
        )
        let outputSize = scaledOutputSize(for: baseCaptureSize)
        currentCaptureSize = outputSize
        currentEncodedSize = outputSize
        captureMode = .display
        updateQueueLimits()
        let width = max(1, Int(outputSize.width))
        let height = max(1, Int(outputSize.height))
        MirageLogger.stream("Desktop encoding at \(width)x\(height) (latency=\(latencyMode.displayName), scale=\(streamScale), queue=\(maxQueuedBytes / 1024)KB)")
        try await encoder.createSession(width: width, height: height)

        try await encoder.preheat()
        shouldEncodeFrames = false
        MirageLogger.stream("Waiting for UDP registration before encoding")

        let streamID = self.streamID
        var localFrameNumber: UInt32 = 0
        var localSequenceNumber: UInt32 = 0

        await encoder.startEncoding(
            onEncodedFrame: { [weak self] encodedData, isKeyframe, presentationTime in
            guard let self else { return }

            let contentRect = self.currentContentRect
            let frameNum = localFrameNumber
            let seqStart = localSequenceNumber
            let totalFragments = (encodedData.count + maxPayloadSize - 1) / maxPayloadSize
            localSequenceNumber += UInt32(totalFragments)
            localFrameNumber += 1

            let flags = self.baseFrameFlags.union(self.dynamicFrameFlags)
            let dimToken = self.dimensionToken
            let epoch = self.epoch

            let generation = packetSender.currentGenerationSnapshot()
            if isKeyframe {
                Task(priority: .userInitiated) {
                    await self.markKeyframeInFlight()
                    await self.markKeyframeSent()
                }
            }
            let workItem = StreamPacketSender.WorkItem(
                encodedData: encodedData,
                isKeyframe: isKeyframe,
                presentationTime: presentationTime,
                contentRect: contentRect,
                streamID: streamID,
                frameNumber: frameNum,
                sequenceNumberStart: seqStart,
                additionalFlags: flags,
                dimensionToken: dimToken,
                epoch: epoch,
                logPrefix: "Desktop frame",
                generation: generation,
                onSendStart: nil,
                onSendComplete: nil
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate
        )
        self.captureEngine = captureEngine

        let captureSizeForSCK = CGVirtualDisplayBridge.isMirageDisplay(display.displayID) ? outputSize : nil
        try await captureEngine.startDisplayCapture(
            display: display,
            resolution: captureSizeForSCK,
            showsCursor: false
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        startCadenceTaskIfNeeded()

        MirageLogger.stream("Started desktop display stream \(streamID) at \(width)x\(height)")
    }
}

#endif
