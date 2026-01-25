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
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        clientDisplayResolution: CGSize,
        onEncodedFrame: @escaping @Sendable (Data, FrameHeader, @escaping @Sendable () -> Void) -> Void,
        onContentBoundsChanged: @escaping @Sendable (CGRect) -> Void,
        onNewWindowDetected: @escaping @Sendable (MirageWindow) -> Void,
        onVirtualDisplayReady: @escaping @Sendable (CGRect) async -> Void = { _ in }
    ) async throws {
        guard !isRunning else { return }
        isRunning = true
        useVirtualDisplay = true

        let application = applicationWrapper.application

        self.onEncodedPacket = onEncodedFrame
        self.onContentBoundsChanged = onContentBoundsChanged
        self.onNewWindowDetected = onNewWindowDetected
        let packetSender = StreamPacketSender(maxPayloadSize: maxPayloadSize, onEncodedFrame: onEncodedFrame)
        self.packetSender = packetSender
        await packetSender.start()

        MirageLogger.stream("Starting stream \(streamID) with shared virtual display at \(Int(clientDisplayResolution.width))x\(Int(clientDisplayResolution.height))")

        let vdContext = try await SharedVirtualDisplayManager.shared.acquireDisplay(
            for: streamID,
            clientResolution: clientDisplayResolution,
            windowID: windowID,
            refreshRate: currentFrameRate,
            colorSpace: encoderConfig.colorSpace
        )
        self.virtualDisplayContext = vdContext

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(vdContext.displayID, knownResolution: vdContext.resolution)
        await onVirtualDisplayReady(displayBounds)

        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: vdContext.spaceID,
            displayID: vdContext.displayID,
            displayBounds: displayBounds
        )

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirageError.protocolError("Window \(windowID) not found after moving to virtual display")
        }
        guard let scApp = content.applications.first(where: { $0.processID == application.processID }) else {
            throw MirageError.protocolError("Application (PID \(application.processID)) not found")
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == vdContext.displayID }) else {
            throw MirageError.protocolError("Virtual display \(vdContext.displayID) not found in SCShareableContent")
        }

        let windowWrapper = SCWindowWrapper(window: scWindow)
        let appWrapper = SCApplicationWrapper(application: scApp)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        MirageLogger.stream("Found SCWindow \(scWindow.windowID) on virtual display \(scDisplay.displayID)")

        let encoder = HEVCEncoder(configuration: encoderConfig, inFlightLimit: maxInFlightFrames)
        self.encoder = encoder

        let captureScaleFactor: CGFloat = 2.0
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
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
        lastWindowFrame = scWindow.frame
        updateQueueLimits()
        MirageLogger.stream("Virtual display init: scale=\(streamScale), encoded=\(Int(outputSize.width))x\(Int(outputSize.height)), queue=\(maxQueuedBytes / 1024)KB")
        try await encoder.createSession(
            width: Int(outputSize.width),
            height: Int(outputSize.height)
        )
        MirageLogger.encoder("Encoder created at scaled dimensions \(Int(outputSize.width))x\(Int(outputSize.height)) (capture \(captureTarget.width)x\(captureTarget.height), window \(Int(scWindow.frame.width))x\(Int(scWindow.frame.height)) × \(captureScaleFactor))")

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
                logPrefix: "VD Frame",
                generation: generation
            )
            packetSender.enqueue(workItem)
        }, onFrameComplete: { [weak self] in
            Task(priority: .userInitiated) { await self?.finishEncoding() }
        })

        let resolvedPixelFormat = await encoder.getActivePixelFormat()
        activePixelFormat = resolvedPixelFormat
        let captureConfig = encoderConfig.withOverrides(pixelFormat: resolvedPixelFormat)
        let windowCaptureEngine = WindowCaptureEngine(configuration: captureConfig)
        self.captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: windowWrapper.window,
            application: appWrapper.application,
            display: displayWrapper.display,
            knownScaleFactor: 2.0,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        MirageLogger.stream("Started stream \(streamID) with virtual display \(vdContext.displayID) for window \(windowID)")
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

        MirageLogger.stream("Updating shared virtual display for client resolution \(Int(newResolution.width))x\(Int(newResolution.height)) (frames paused)")

        await captureEngine?.stopCapture()

        try await SharedVirtualDisplayManager.shared.updateClientResolution(
            for: streamID,
            newResolution: newResolution,
            refreshRate: currentFrameRate
        )

        guard let newContext = await SharedVirtualDisplayManager.shared.getDisplayContext() else {
            throw MirageError.protocolError("No shared virtual display available after resolution update")
        }
        self.virtualDisplayContext = newContext

        let displayBounds = CGVirtualDisplayBridge.getDisplayBounds(newContext.displayID, knownResolution: newContext.resolution)
        try await WindowSpaceManager.shared.moveWindow(
            windowID,
            toSpaceID: newContext.spaceID,
            displayID: newContext.displayID,
            displayBounds: displayBounds
        )

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let scWindow = content.windows.first(where: { $0.windowID == windowID }) else {
            throw MirageError.protocolError("Window \(windowID) not found after virtual display update")
        }
        guard let scDisplay = content.displays.first(where: { $0.displayID == newContext.displayID }) else {
            throw MirageError.protocolError("Virtual display \(newContext.displayID) not found")
        }

        let windowList = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[CFString: Any]]
        let pid = windowList?.first?[kCGWindowOwnerPID] as? pid_t ?? 0
        guard let scApp = content.applications.first(where: { $0.processID == pid }) else {
            throw MirageError.protocolError("Application (PID \(pid)) not found")
        }

        let windowWrapper = SCWindowWrapper(window: scWindow)
        let appWrapper = SCApplicationWrapper(application: scApp)
        let displayWrapper = SCDisplayWrapper(display: scDisplay)

        let captureScaleFactor: CGFloat = 2.0
        let captureTarget = streamTargetDimensions(windowFrame: scWindow.frame, scaleFactor: captureScaleFactor)
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
        lastWindowFrame = scWindow.frame
        updateQueueLimits()
        if let encoder {
            try await encoder.updateDimensions(
                width: Int(outputSize.width),
                height: Int(outputSize.height)
            )
            MirageLogger.encoder("Encoder updated to \(Int(outputSize.width))x\(Int(outputSize.height)) for resolution change")
        }

        let windowCaptureEngine = WindowCaptureEngine(configuration: encoderConfig)
        self.captureEngine = windowCaptureEngine

        try await windowCaptureEngine.startCapture(
            window: windowWrapper.window,
            application: appWrapper.application,
            display: displayWrapper.display,
            knownScaleFactor: 2.0,
            outputScale: streamScale
        ) { [weak self] frame in
            self?.enqueueCapturedFrame(frame)
        }

        await encoder?.forceKeyframe()

        MirageLogger.stream("Virtual display resolution update complete (frames resumed)")
    }
}

#endif
