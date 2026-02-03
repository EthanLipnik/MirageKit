//
//  StreamContext+Streaming+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Virtual display streaming paths.
//

import Foundation

#if os(macOS)
import ScreenCaptureKit

extension StreamContext {
    func startWithVirtualDisplay(
        windowWrapper _: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientDisplayResolution: CGSize,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void,
        onVirtualDisplayReady: @escaping @Sendable (CGRect) async -> Void = { _ in }
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
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        MirageLogger
            .stream(
                "Starting stream \(streamID) with shared virtual display at \(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height))"
            )

        let vdContext = try await SharedVirtualDisplayManager.shared.acquireDisplay(
            for: streamID,
            clientResolution: clientDisplayResolution,
            windowID: windowID,
            refreshRate: virtualDisplayRefreshRate,
            colorSpace: encoderConfig.colorSpace
        )
        virtualDisplayContext = vdContext
        sharedDisplayGeneration = vdContext.generation

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            vdContext.displayID,
            knownResolution: vdContext.resolution
        )
        await onVirtualDisplayReady(displayBounds)

        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdContext.spaceID,
            displayID: vdContext.displayID,
            displayBounds: displayBounds
        )

        let resolvedTargets = try await resolveVirtualDisplayTargets(
            windowID: windowID,
            applicationPID: applicationProcessID,
            displayID: vdContext.displayID,
            label: "virtual display start"
        )
        let scWindow = resolvedTargets.window.window
        let resolvedWindowWrapper = resolvedTargets.window
        let resolvedAppWrapper = resolvedTargets.application
        let resolvedDisplayWrapper = resolvedTargets.display

        let resolvedDisplayID = resolvedDisplayWrapper.display.displayID
        if !CGVirtualDisplayBridge.isMirageDisplay(resolvedDisplayID) {
            MirageLogger.error(.stream, "Expected virtual display capture, got display \(resolvedDisplayID)")
        }
        MirageLogger
            .stream(
                "Resolved SCWindow \(scWindow.windowID) on virtual display \(resolvedDisplayID)"
            )

        let captureScaleFactor: CGFloat = 2.0
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
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
        lastWindowFrame = scWindow.frame
        updateQueueLimits()
        await applyDerivedQuality(for: outputSize, logLabel: "Virtual display init")
        MirageLogger
            .stream(
                "Virtual display init: latency=\(latencyMode.displayName), scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB"
            )
        let encoder = HEVCEncoder(
            configuration: encoderConfig,
            latencyMode: latencyMode,
            inFlightLimit: maxInFlightFrames
        )
        self.encoder = encoder
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger
            .encoder(
                "Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (capture \(captureTarget.width)x\(captureTarget.height), window \(Int(scWindow.frame.width))x\(Int(scWindow.frame.height)) × \(captureScaleFactor))"
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
                let lossModeActive = isLossModeActive(now: now)
                let fecBlockSize = lossModeActive ? (isKeyframe ? 8 : 16) : 0
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
                    lossMode: lossModeActive,
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
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: true
        )
        captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: resolvedWindowWrapper.window,
            application: resolvedAppWrapper.application,
            display: resolvedDisplayWrapper.display,
            knownScaleFactor: 2.0,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }
        await refreshCaptureCadence()

        MirageLogger
            .stream("Started stream \(streamID) with virtual display \(vdContext.displayID) for window \(windowID)")
    }

    func updateVirtualDisplayResolution(newResolution: CGSize) async throws {
        guard isRunning, useVirtualDisplay else { return }

        isResizing = true
        defer { isResizing = false }

        currentContentRect = .zero

        dimensionToken &+= 1
        MirageLogger.stream("Dimension token incremented to \(dimensionToken)")
        await packetSender?.bumpGeneration(reason: "virtual display resize")
        resetPipelineStateForReconfiguration(reason: "virtual display resize")

        MirageLogger
            .stream(
                "Updating shared virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)"
            )

        await captureEngine?.stopCapture()

        try await SharedVirtualDisplayManager.shared.updateClientResolution(
            for: streamID,
            newResolution: newResolution,
            refreshRate: SharedVirtualDisplayManager.streamRefreshRate(for: currentFrameRate)
        )

        guard let newContext = await SharedVirtualDisplayManager.shared.getDisplaySnapshot() else { throw MirageError.protocolError("No shared virtual display available after resolution update") }
        virtualDisplayContext = newContext
        sharedDisplayGeneration = newContext.generation

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(
            newContext.displayID,
            knownResolution: newContext.resolution
        )
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: newContext.spaceID,
            displayID: newContext.displayID,
            displayBounds: displayBounds
        )

        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]
        if let pid = windowList?.first?[kCGWindowOwnerPID] as? pid_t, pid > 0 { applicationProcessID = pid }
        guard applicationProcessID > 0 else { throw MirageError.protocolError("Application PID unavailable for virtual display update") }
        let resolvedTargets = try await resolveVirtualDisplayTargets(
            windowID: windowID,
            applicationPID: applicationProcessID,
            displayID: newContext.displayID,
            label: "virtual display update"
        )
        let scWindow = resolvedTargets.window.window
        let resolvedWindowWrapper = resolvedTargets.window
        let resolvedAppWrapper = resolvedTargets.application
        let resolvedDisplayWrapper = resolvedTargets.display

        let captureScaleFactor: CGFloat = 2.0
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
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
        lastWindowFrame = scWindow.frame
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

        let captureConfig = encoderConfig.withOverrides(pixelFormat: activePixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(
            configuration: captureConfig,
            latencyMode: latencyMode,
            captureFrameRate: captureFrameRate
        )
        captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: resolvedWindowWrapper.window,
            application: resolvedAppWrapper.application,
            display: resolvedDisplayWrapper.display,
            knownScaleFactor: 2.0,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }
        await refreshCaptureCadence()

        await encoder?.forceKeyframe()

        MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
    }
}

#endif
