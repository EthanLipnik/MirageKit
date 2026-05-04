//
//  AppAtlasMediaCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/3/26.
//

import CoreMedia
import CoreVideo
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

struct AppAtlasWindowAttachment: Sendable {
    let streamID: StreamID
    let mediaStreamID: StreamID
    let windowID: WindowID
    let title: String?
    let width: Int
    let height: Int
    let isResizable: Bool
    let atlasRegion: MirageAppAtlasRegion
    let atlasLayouts: [MirageAppAtlasLayout]
}

actor AppAtlasWindowCaptureContext {
    let windowID: WindowID
    private(set) var captureEngine: WindowCaptureEngine?
    private(set) var isCapturing = false

    init(windowID: WindowID) {
        self.windowID = windowID
    }

    func startCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        encoderConfig: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        targetFrameRate: Int,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void
    ) async throws {
        guard !isCapturing else { return }

        let engine = WindowCaptureEngine(
            configuration: encoderConfig,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            captureFrameRate: targetFrameRate,
            usesDisplayRefreshCadence: false
        )
        captureEngine = engine
        try await engine.startCapture(
            window: windowWrapper.window,
            application: applicationWrapper.application,
            display: displayWrapper.display,
            outputScale: 1.0,
            onFrame: onFrame
        )
        isCapturing = true
    }

    func stop() async {
        guard isCapturing else {
            captureEngine = nil
            return
        }
        isCapturing = false
        await captureEngine?.stopCapture()
        captureEngine = nil
    }
}

actor AppAtlasMediaCoordinator {
    private struct LogicalWindow: Sendable {
        let streamID: StreamID
        let windowID: WindowID
        var title: String?
        var pointSize: CGSize
        var pixelSize: CGSize
        var sourceRect: CGRect
        var isResizable: Bool
    }

    let clientID: UUID
    let mediaStreamID: StreamID

    private let context: StreamContext
    private let encoderConfig: MirageEncoderConfiguration
    private let latencyMode: MirageStreamLatencyMode
    private let capturePressureProfile: WindowCaptureEngine.CapturePressureProfile
    private let targetFrameRate: Int
    private let sendPacket: @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void
    private let onSendError: @Sendable (Error) -> Void
    private let sendMediaUpdate: @MainActor @Sendable (AppAtlasMediaUpdateMessage) async -> Void

    private var frameSink: MirageCustomStreamFrameSink?
    private var startupAttemptID: UUID?
    private var capturesByWindowID: [WindowID: AppAtlasWindowCaptureContext] = [:]
    private var logicalWindowsByWindowID: [WindowID: LogicalWindow] = [:]
    private var windowIDByStreamID: [StreamID: WindowID] = [:]
    private var latestFramesByWindowID: [WindowID: CapturedFrame] = [:]
    private var compositor: AppAtlasFrameCompositor?
    private var layoutEpoch: UInt64 = 0
    private var currentLayout: AppAtlasLayout.Result?
    private var currentPublicLayout: MirageAppAtlasLayout?
    private var compositionTask: Task<Void, Never>?
    private var isStopped = false

    init(
        clientID: UUID,
        mediaStreamID: StreamID,
        context: StreamContext,
        encoderConfig: MirageEncoderConfiguration,
        latencyMode: MirageStreamLatencyMode,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        targetFrameRate: Int,
        sendPacket: @escaping @Sendable (Data, @escaping @Sendable (Error?) -> Void) -> Void,
        onSendError: @escaping @Sendable (Error) -> Void,
        sendMediaUpdate: @escaping @MainActor @Sendable (AppAtlasMediaUpdateMessage) async -> Void
    ) {
        self.clientID = clientID
        self.mediaStreamID = mediaStreamID
        self.context = context
        self.encoderConfig = encoderConfig
        self.latencyMode = latencyMode
        self.capturePressureProfile = capturePressureProfile
        self.targetFrameRate = max(1, targetFrameRate)
        self.sendPacket = sendPacket
        self.onSendError = onSendError
        self.sendMediaUpdate = sendMediaUpdate
    }

    var isEmpty: Bool {
        logicalWindowsByWindowID.isEmpty
    }

    func logicalStreamIDs() -> [StreamID] {
        logicalWindowsByWindowID.values.map(\.streamID).sorted()
    }

    func addWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        isResizable: Bool
    ) async throws -> AppAtlasWindowAttachment {
        try await attachWindow(
            streamID: streamID,
            window: window,
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            isResizable: isResizable,
            replacingExistingStreamBinding: false,
            reason: "window added"
        )
    }

    func replaceWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        isResizable: Bool
    ) async throws -> AppAtlasWindowAttachment {
        try await attachWindow(
            streamID: streamID,
            window: window,
            windowWrapper: windowWrapper,
            applicationWrapper: applicationWrapper,
            displayWrapper: displayWrapper,
            isResizable: isResizable,
            replacingExistingStreamBinding: true,
            reason: "window replaced"
        )
    }

    private func attachWindow(
        streamID: StreamID,
        window: MirageWindow,
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        isResizable: Bool,
        replacingExistingStreamBinding: Bool,
        reason: String
    ) async throws -> AppAtlasWindowAttachment {
        guard !isStopped else { throw CancellationError() }

        let windowID = window.id
        if let existing = logicalWindowsByWindowID[windowID] {
            guard existing.streamID == streamID else {
                throw MirageError.protocolError("App-atlas window \(windowID) is already bound to stream \(existing.streamID)")
            }
            return try await attachment(for: existing)
        }
        if !replacingExistingStreamBinding, let existingWindowID = windowIDByStreamID[streamID] {
            throw MirageError.protocolError("App-atlas stream \(streamID) is already bound to window \(existingWindowID)")
        }
        if capturesByWindowID[windowID] != nil {
            throw MirageError.protocolError("App-atlas window \(windowID) capture is already starting")
        }

        let captureContext = AppAtlasWindowCaptureContext(windowID: windowID)
        let target = streamTargetDimensions(windowFrame: windowWrapper.window.frame)
        let pixelSize = CGSize(width: target.width, height: target.height)
        var logicalWindow = LogicalWindow(
            streamID: streamID,
            windowID: windowID,
            title: window.title,
            pointSize: window.frame.size,
            pixelSize: pixelSize,
            sourceRect: CGRect(origin: .zero, size: pixelSize),
            isResizable: isResizable
        )

        capturesByWindowID[windowID] = captureContext
        do {
            try await captureContext.startCapture(
                windowWrapper: windowWrapper,
                applicationWrapper: applicationWrapper,
                displayWrapper: displayWrapper,
                encoderConfig: encoderConfig,
                latencyMode: latencyMode,
                capturePressureProfile: capturePressureProfile,
                targetFrameRate: targetFrameRate,
                onFrame: { [weak self] frame in
                    Task(priority: .userInitiated) {
                        await self?.recordFrame(frame, windowID: windowID)
                    }
                }
            )
        } catch {
            capturesByWindowID.removeValue(forKey: windowID)
            await captureContext.stop()
            throw error
        }

        guard !isStopped else {
            capturesByWindowID.removeValue(forKey: windowID)
            await captureContext.stop()
            throw CancellationError()
        }

        let oldWindowID = replacingExistingStreamBinding ? windowIDByStreamID[streamID] : nil
        let oldLogicalWindow = oldWindowID.flatMap { logicalWindowsByWindowID[$0] }
        let oldLatestFrame = oldWindowID.flatMap { latestFramesByWindowID[$0] }
        let oldCapture = oldWindowID.flatMap { capturesByWindowID.removeValue(forKey: $0) }
        if let oldWindowID {
            logicalWindowsByWindowID.removeValue(forKey: oldWindowID)
            latestFramesByWindowID.removeValue(forKey: oldWindowID)
        }

        if let latestFrame = latestFramesByWindowID[windowID] {
            let latestPixelSize = Self.pixelSize(for: latestFrame)
            logicalWindow.pixelSize = latestPixelSize
            logicalWindow.sourceRect = Self.normalizedSourceRect(
                contentRect: latestFrame.info.contentRect,
                pixelSize: latestPixelSize
            )
        }

        logicalWindowsByWindowID[windowID] = logicalWindow
        windowIDByStreamID[streamID] = windowID

        do {
            try await recomputeLayoutAndNotify(reason: reason)
            startCompositionLoopIfNeeded()
        } catch {
            capturesByWindowID.removeValue(forKey: windowID)
            logicalWindowsByWindowID.removeValue(forKey: windowID)
            latestFramesByWindowID.removeValue(forKey: windowID)
            if let oldWindowID, let oldCapture {
                capturesByWindowID[oldWindowID] = oldCapture
                if let oldLogicalWindow {
                    logicalWindowsByWindowID[oldWindowID] = oldLogicalWindow
                }
                if let oldLatestFrame {
                    latestFramesByWindowID[oldWindowID] = oldLatestFrame
                }
                windowIDByStreamID[streamID] = oldWindowID
            } else {
                windowIDByStreamID.removeValue(forKey: streamID)
            }
            await captureContext.stop()
            throw error
        }

        await oldCapture?.stop()
        return try await attachment(for: logicalWindow)
    }

    func removeWindow(streamID: StreamID) async {
        guard let windowID = windowIDByStreamID.removeValue(forKey: streamID) else { return }
        logicalWindowsByWindowID.removeValue(forKey: windowID)
        latestFramesByWindowID.removeValue(forKey: windowID)
        let capture = capturesByWindowID.removeValue(forKey: windowID)
        await capture?.stop()
        do {
            try await recomputeLayoutAndNotify(reason: "window removed")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update app-atlas layout after window removal: ")
        }
    }

    func stop() async {
        isStopped = true
        compositionTask?.cancel()
        compositionTask = nil
        let captures = capturesByWindowID.values
        capturesByWindowID.removeAll()
        logicalWindowsByWindowID.removeAll()
        windowIDByStreamID.removeAll()
        latestFramesByWindowID.removeAll()
        frameSink = nil
        compositor = nil
        currentLayout = nil
        currentPublicLayout = nil
        for capture in captures {
            await capture.stop()
        }
        await context.stop()
    }

    func atlasLayouts() -> [MirageAppAtlasLayout] {
        currentPublicLayout.map { [$0] } ?? []
    }

    func atlasRegion(windowID: WindowID) -> MirageAppAtlasRegion? {
        currentPublicLayout?.region(for: windowID)
    }

    private func recordFrame(_ frame: CapturedFrame, windowID: WindowID) async {
        latestFramesByWindowID[windowID] = frame
        let pixelSize = Self.pixelSize(for: frame)
        let sourceRect = Self.normalizedSourceRect(
            contentRect: frame.info.contentRect,
            pixelSize: pixelSize
        )
        guard var logicalWindow = logicalWindowsByWindowID[windowID],
              logicalWindow.pixelSize != pixelSize || logicalWindow.sourceRect != sourceRect else {
            return
        }

        logicalWindow.pixelSize = pixelSize
        logicalWindow.sourceRect = sourceRect
        logicalWindowsByWindowID[windowID] = logicalWindow
        do {
            try await recomputeLayoutAndNotify(reason: "capture geometry changed")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to update app-atlas layout after capture resize: ")
        }
    }

    private func recomputeLayoutAndNotify(reason: String) async throws {
        let windows = logicalWindowsByWindowID.values
            .sorted { lhs, rhs in lhs.streamID < rhs.streamID }
            .map { window in
                AppAtlasLayout.Window(
                    id: window.windowID,
                    sourceRect: window.sourceRect
                )
            }
        let nextLayout = AppAtlasLayout.nativePackedLayout(windows: windows)
        guard !nextLayout.isEmpty else {
            currentLayout = nil
            currentPublicLayout = nil
            return
        }

        let previousCanvas = currentLayout?.canvasSize ?? .zero
        let previousPlacements = currentLayout?.placements ?? []
        let canvasChanged = previousCanvas != nextLayout.canvasSize
        let placementsChanged = previousPlacements != nextLayout.placements
        guard canvasChanged || placementsChanged else { return }

        layoutEpoch &+= 1
        currentLayout = nextLayout
        if frameSink == nil {
            try await startMediaStreamIfNeeded(pixelSize: nextLayout.canvasSize)
        } else if canvasChanged {
            try await context.updateAppAtlasDimensionsIfNeeded(pixelSize: nextLayout.canvasSize)
        }

        let publicLayout = nextLayout.makePublicLayout(
            mediaStreamID: mediaStreamID,
            layoutEpoch: layoutEpoch,
            focusedWindowID: logicalWindowsByWindowID.values.sorted { $0.streamID < $1.streamID }.first?.windowID
        )
        currentPublicLayout = publicLayout
        try await sendCurrentMediaUpdate(layout: publicLayout)
        MirageLogger.host(
            "App atlas layout updated mediaStream=\(mediaStreamID) reason=\(reason) " +
                "epoch=\(layoutEpoch) size=\(publicLayout.width)x\(publicLayout.height) regions=\(publicLayout.regions.count)"
        )
    }

    private func startMediaStreamIfNeeded(pixelSize: CGSize) async throws {
        guard frameSink == nil else { return }
        let attemptID = startupAttemptID ?? UUID()
        startupAttemptID = attemptID
        frameSink = try await context.startAppAtlasFrameStream(
            pixelSize: pixelSize,
            sendPacket: sendPacket,
            onSendError: onSendError
        )
        await context.allowEncodingAfterRegistration()
    }

    private func sendCurrentMediaUpdate(layout: MirageAppAtlasLayout) async throws {
        let dimensions = await context.getEncodedDimensions()
        let codec = await context.getCodec()
        let frameRate = await context.getTargetFrameRate()
        let dimensionToken = await context.getDimensionToken()
        let acceptedPacketSize = await context.getMediaMaxPacketSize()
        let message = AppAtlasMediaUpdateMessage(
            mediaStreamID: mediaStreamID,
            width: dimensions.width,
            height: dimensions.height,
            codec: codec,
            frameRate: frameRate,
            dimensionToken: dimensionToken,
            layoutEpoch: layout.layoutEpoch,
            acceptedPacketSize: acceptedPacketSize,
            layout: layout,
            startupAttemptID: startupAttemptID ?? UUID()
        )
        await sendMediaUpdate(message)
    }

    private func attachment(for window: LogicalWindow) async throws -> AppAtlasWindowAttachment {
        guard let layout = currentPublicLayout,
              let region = layout.region(for: window.windowID) else {
            throw MirageError.protocolError("App-atlas layout missing region for window \(window.windowID)")
        }
        return AppAtlasWindowAttachment(
            streamID: window.streamID,
            mediaStreamID: mediaStreamID,
            windowID: window.windowID,
            title: window.title,
            width: Int(max(1, window.pointSize.width.rounded())),
            height: Int(max(1, window.pointSize.height.rounded())),
            isResizable: window.isResizable,
            atlasRegion: region,
            atlasLayouts: [layout]
        )
    }

    private func startCompositionLoopIfNeeded() {
        guard compositionTask == nil else { return }
        compositionTask = Task(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let fps = max(1, await self.targetFrameRateSnapshot())
            let frameDuration = Duration.nanoseconds(Int64(max(1, 1_000_000_000 / UInt64(fps))))
            while !Task.isCancelled {
                await self.emitAtlasFrameIfPossible()
                do {
                    try await Task.sleep(for: frameDuration)
                } catch {
                    return
                }
            }
        }
    }

    private func targetFrameRateSnapshot() -> Int {
        targetFrameRate
    }

    private nonisolated static func pixelSize(for frame: CapturedFrame) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(frame.pixelBuffer), height: CVPixelBufferGetHeight(frame.pixelBuffer))
    }

    private func emitAtlasFrameIfPossible() async {
        guard let frameSink,
              let layout = currentLayout,
              !latestFramesByWindowID.isEmpty else {
            return
        }

        do {
            if compositor == nil {
                compositor = try AppAtlasFrameCompositor()
            }
            guard let compositor else { return }
            try await context.updateAppAtlasDimensionsIfNeeded(pixelSize: layout.canvasSize)
            let pixelBuffer = try compositor.compose(
                framesByWindowID: latestFramesByWindowID,
                layout: layout
            )
            let presentationTime = latestFramesByWindowID.values
                .map(\.presentationTime)
                .max { CMTimeCompare($0, $1) < 0 } ?? CMTime(
                    seconds: CFAbsoluteTimeGetCurrent(),
                    preferredTimescale: 1_000_000_000
                )
            let duration = CMTime(value: 1, timescale: CMTimeScale(max(1, targetFrameRate)))
            let contentRect = CGRect(origin: .zero, size: layout.canvasSize)
            let frame = MirageCustomStreamFrame(
                pixelBuffer: pixelBuffer,
                presentationTime: presentationTime,
                duration: duration,
                contentRect: contentRect,
                dirtyPercentage: 100,
                isIdleFrame: false
            )
            frameSink.submit(frame)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to emit app-atlas frame: ")
        }
    }
}
#endif
