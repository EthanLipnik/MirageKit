//
//  MacOSHostCaptureSourceBackend.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Live macOS implementation of host capture source startup.
final class MacOSHostCaptureSourceBackend: @unchecked Sendable, MirageHostCaptureSourceBackend {
    private let captureEngineFactoryBackend: any MirageHostCaptureEngineFactoryBackend
    private let captureContentProviderBackend: any MirageHostCaptureContentProviderBackend
    private let stateLock = NSLock()
    private var captureEngine: WindowCaptureEngine?
    private var isStarting = false
    private var videoFrameStream: AsyncStream<CapturedFrame>?
    private var videoContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var audioBufferStream: AsyncStream<CapturedAudioBuffer>?
    private var audioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?

    init(
        captureEngineFactoryBackend: any MirageHostCaptureEngineFactoryBackend =
            MacOSHostCaptureEngineFactoryBackend(),
        captureContentProviderBackend: any MirageHostCaptureContentProviderBackend =
            MacOSHostCaptureContentProviderBackend()
    ) {
        self.captureEngineFactoryBackend = captureEngineFactoryBackend
        self.captureContentProviderBackend = captureContentProviderBackend
    }

    func startCapture(_ request: MirageHostCaptureRequest) async throws {
        let engine = makeCaptureEngine(for: request.configuration)

        try await startCapture(
            request,
            using: engine,
            onFrame: { [weak self] frame in
                self?.yield(frame)
            },
            onAudio: { [weak self] buffer in
                self?.yield(buffer)
            }
        )
    }

    func startCapture(
        _ request: MirageHostCaptureRequest,
        using engine: WindowCaptureEngine,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?
    ) async throws {
        try reserveStart()

        do {
            let contentWrapper = try await captureContentProviderBackend.shareableContent()
            try await startCapture(
                request,
                content: contentWrapper,
                engine: engine,
                onFrame: onFrame,
                onAudio: onAudio
            )
            finishStart(engine: engine)
            MirageLogger.capture("macOS host capture source backend started source=\(request.source.logDescription)")
        } catch {
            await engine.stopCapture()
            cancelStart()
            throw error
        }
    }

    func videoFrames() -> AsyncStream<CapturedFrame> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return videoFrameStreamLocked()
    }

    func audioBuffers() -> AsyncStream<CapturedAudioBuffer> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioBufferStreamLocked()
    }

    func stopCapture() async {
        let stoppedState = takeStoppedState()
        await stoppedState.captureEngine?.stopCapture()
        stoppedState.videoContinuation?.finish()
        stoppedState.audioContinuation?.finish()
    }

    var hasActiveCaptureEngine: Bool { activeCaptureEngine() != nil }

    @discardableResult
    func setCapturedAudioHandler(_ handler: (@Sendable (CapturedAudioBuffer) -> Void)?) async -> Bool {
        guard let captureEngine = activeCaptureEngine() else { return false }
        await captureEngine.setCapturedAudioHandler(handler)
        return true
    }

    @discardableResult
    func setCaptureStallStageHandler(_ handler: (@Sendable (CaptureStreamOutput.StallStage) -> Void)?) async -> Bool {
        guard let captureEngine = activeCaptureEngine() else { return false }
        await captureEngine.setCaptureStallStageHandler(handler)
        return true
    }

    @discardableResult
    func restartCapture(reason: String) async -> Bool {
        guard let captureEngine = activeCaptureEngine() else { return false }
        return await captureEngine.restartCapture(reason: reason)
    }

    func minimumFrameIntervalRate() async -> Int? {
        guard let captureEngine = activeCaptureEngine() else { return nil }
        return await captureEngine.minimumFrameIntervalRate
    }

    func updateResolution(width: Int, height: Int) async throws {
        guard let captureEngine = activeCaptureEngine() else { return }
        try await captureEngine.updateResolution(width: width, height: height)
    }

    func updateDimensions(windowFrame: CGRect, outputScale: CGFloat) async throws {
        guard let captureEngine = activeCaptureEngine() else { return }
        try await captureEngine.updateDimensions(windowFrame: windowFrame, outputScale: outputScale)
    }

    func updateShowsCursor(_ showsCursor: Bool) async throws {
        guard let captureEngine = activeCaptureEngine() else { return }
        try await captureEngine.updateShowsCursor(showsCursor)
    }

    func waitForCaptureStartupReadiness(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> DisplayCaptureStartupReadiness {
        guard let captureEngine = activeCaptureEngine() else { return .noScreenSamples }
        return await captureEngine.waitForCaptureStartupReadiness(
            timeout: timeout,
            pollInterval: pollInterval
        )
    }

    func waitForDisplayStartupReadiness(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(50)
    ) async -> DisplayCaptureStartupReadiness {
        guard let captureEngine = activeCaptureEngine() else { return .noScreenSamples }
        return await captureEngine.waitForDisplayStartupReadiness(
            timeout: timeout,
            pollInterval: pollInterval
        )
    }

    func hasObservedDisplayStartupSample() async -> Bool {
        guard let captureEngine = activeCaptureEngine() else { return false }
        return await captureEngine.hasObservedDisplayStartupSample
    }

    func displayStartupReadiness() async -> DisplayCaptureStartupReadiness {
        guard let captureEngine = activeCaptureEngine() else { return .noScreenSamples }
        return await captureEngine.displayStartupReadiness
    }

    func captureStartupReadiness() async -> DisplayCaptureStartupReadiness {
        guard let captureEngine = activeCaptureEngine() else { return .noScreenSamples }
        return await captureEngine.captureStartupReadiness
    }

    func capturePolicySnapshot() async -> WindowCaptureEngine.CapturePolicySnapshot? {
        guard let captureEngine = activeCaptureEngine() else { return nil }
        return await captureEngine.capturePolicySnapshot
    }

    func captureTelemetrySnapshot() async -> CaptureStreamOutput.TelemetrySnapshot? {
        guard let captureEngine = activeCaptureEngine() else { return nil }
        return await captureEngine.captureTelemetrySnapshot
    }

    func consumeCaptureTelemetrySnapshot() async -> CaptureStreamOutput.TelemetrySnapshot? {
        guard let captureEngine = activeCaptureEngine() else { return nil }
        return await captureEngine.consumeCaptureTelemetrySnapshot()
    }

    func captureDisplayStartupSeedFrame() async -> CapturedFrame? {
        guard let captureEngine = activeCaptureEngine() else { return nil }
        return await captureEngine.captureDisplayStartupSeedFrame()
    }

    private func makeCaptureEngine(for configuration: MirageHostCaptureConfiguration) -> WindowCaptureEngine {
        let encoderConfiguration = MirageEncoderConfiguration.highQuality
            .withTargetFrameRate(configuration.targetFrameRate)
            .withOverrides(captureQueueDepth: configuration.queueDepth)
        return captureEngineFactoryBackend.makeCaptureEngine(
            configuration: encoderConfiguration,
            capturePressureProfile: .baseline,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            captureFrameRate: configuration.targetFrameRate,
            usesDisplayRefreshCadence: false
        )
    }

    private func startCapture(
        _ request: MirageHostCaptureRequest,
        content: SCShareableContentWrapper,
        engine: WindowCaptureEngine,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?
    ) async throws {
        let onAudio = audioHandler(for: request, handler: onAudio)
        switch request.source {
        case let .display(displayID):
            let displayWrapper = try resolveDisplay(displayID, in: content)
            try await engine.startCapture(
                displayWrapper: displayWrapper,
                resolution: request.configuration.captureResolution,
                sourceRect: request.configuration.sourceRect,
                destinationRect: request.configuration.destinationRect,
                showsCursor: request.configuration.showsCursor,
                onFrame: onFrame,
                onAudio: onAudio,
                audioChannelCount: audioChannelCount(for: request)
            )
        case let .window(windowID):
            let windowWrapper = try resolveWindow(windowID, in: content)
            guard let application = windowWrapper.window.owningApplication else {
                throw MirageCore.MirageError.windowNotFound
            }
            let applicationWrapper = SCApplicationWrapper(application: application)
            guard let displayWrapper = resolveDisplay(for: windowWrapper, in: content.content.displays) else {
                throw MirageCore.MirageError.protocolError("Unable to resolve display for capture window \(windowID)")
            }
            try await engine.startCapture(
                windowWrapper: windowWrapper,
                applicationWrapper: applicationWrapper,
                displayWrapper: displayWrapper,
                outputScale: outputScale(for: windowWrapper.window, request: request),
                onFrame: onFrame,
                onAudio: onAudio,
                audioChannelCount: audioChannelCount(for: request)
            )
        case let .displayWindowSet(displayID, includedWindowIDs, excludedWindowIDs):
            let displayWrapper = try resolveDisplay(displayID, in: content)
            let includedWindowWrappers = resolveWindows(includedWindowIDs, in: content)
            let excludedWindowWrappers = resolveWindows(excludedWindowIDs, in: content)
            try await engine.startCapture(
                displayWrapper: displayWrapper,
                resolution: request.configuration.captureResolution,
                sourceRect: request.configuration.sourceRect,
                destinationRect: request.configuration.destinationRect,
                contentWindowID: request.configuration.contentWindowID ?? includedWindowIDs.first,
                includedWindowWrappers: includedWindowWrappers,
                excludedWindowWrappers: excludedWindowWrappers,
                showsCursor: request.configuration.showsCursor,
                onFrame: onFrame,
                onAudio: onAudio,
                audioChannelCount: audioChannelCount(for: request)
            )
        }
    }

    private func resolveDisplay(
        _ displayID: MirageHostDisplayID,
        in content: SCShareableContentWrapper
    ) throws -> SCDisplayWrapper {
        let resolvedDisplayID = CGDirectDisplayID(displayID.rawValue)
        guard let displayWrapper = content.displayWrapper(for: resolvedDisplayID) else {
            throw MirageCore.MirageError.protocolError(
                "Unable to resolve capture display \(resolvedDisplayID); available displays: \(content.displayIDs)"
            )
        }
        return displayWrapper
    }

    private func resolveWindow(_ windowID: WindowID, in content: SCShareableContentWrapper) throws -> SCWindowWrapper {
        guard let window = content.content.windows.first(where: { WindowID($0.windowID) == windowID }) else {
            throw MirageCore.MirageError.windowNotFound
        }
        return SCWindowWrapper(window: window)
    }

    private func resolveWindows(_ windowIDs: [WindowID], in content: SCShareableContentWrapper) -> [SCWindowWrapper] {
        let requested = Set(windowIDs)
        guard !requested.isEmpty else { return [] }
        return content.content.windows
            .filter { requested.contains(WindowID($0.windowID)) }
            .map(SCWindowWrapper.init(window:))
    }

    private func resolveDisplay(for windowWrapper: SCWindowWrapper, in displays: [SCDisplay]) -> SCDisplayWrapper? {
        guard !displays.isEmpty else { return nil }

        let window = windowWrapper.window
        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return SCDisplayWrapper(display: containingDisplay)
        }

        var bestIntersectionArea: CGFloat = 0
        var bestDisplay: SCDisplay?
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }

        return (bestDisplay ?? displays.first).map(SCDisplayWrapper.init(display:))
    }

    private func outputScale(for window: SCWindow, request: MirageHostCaptureRequest) -> CGFloat {
        let requestedWidth = request.configuration.logicalSize.width
        guard requestedWidth > 0, window.frame.width > 0 else { return 1.0 }
        return max(0.1, min(1.0, requestedWidth / window.frame.width))
    }

    private func audioHandler(
        for request: MirageHostCaptureRequest,
        handler: (@Sendable (CapturedAudioBuffer) -> Void)?
    ) -> (@Sendable (CapturedAudioBuffer) -> Void)? {
        guard request.configuration.capturesAudio,
              request.configuration.audioConfiguration.enabled else {
            return nil
        }
        return handler
    }

    private func audioChannelCount(for request: MirageHostCaptureRequest) -> Int? {
        guard request.configuration.capturesAudio,
              request.configuration.audioConfiguration.enabled else {
            return nil
        }
        return request.configuration.audioChannelCount ??
            request.configuration.audioConfiguration.channelLayout.channelCount
    }

    private func reserveStart() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard captureEngine == nil, !isStarting else {
            throw MirageCore.MirageError.protocolError("macOS host capture source backend is already running")
        }
        isStarting = true
        _ = videoFrameStreamLocked()
        _ = audioBufferStreamLocked()
    }

    private func finishStart(engine: WindowCaptureEngine) {
        stateLock.lock()
        defer { stateLock.unlock() }
        captureEngine = engine
        isStarting = false
    }

    private func cancelStart() {
        stateLock.lock()
        defer { stateLock.unlock() }
        isStarting = false
    }

    private func takeStoppedState() -> (
        captureEngine: WindowCaptureEngine?,
        videoContinuation: AsyncStream<CapturedFrame>.Continuation?,
        audioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let stoppedState = (
            captureEngine: captureEngine,
            videoContinuation: videoContinuation,
            audioContinuation: audioContinuation
        )
        captureEngine = nil
        isStarting = false
        videoFrameStream = nil
        videoContinuation = nil
        audioBufferStream = nil
        audioContinuation = nil
        return stoppedState
    }

    private func activeCaptureEngine() -> WindowCaptureEngine? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return captureEngine
    }

    private func yield(_ frame: CapturedFrame) {
        stateLock.lock()
        let continuation = videoContinuation
        stateLock.unlock()
        continuation?.yield(frame)
    }

    private func yield(_ buffer: CapturedAudioBuffer) {
        stateLock.lock()
        let continuation = audioContinuation
        stateLock.unlock()
        continuation?.yield(buffer)
    }

    private func videoFrameStreamLocked() -> AsyncStream<CapturedFrame> {
        if let videoFrameStream {
            return videoFrameStream
        }
        var continuation: AsyncStream<CapturedFrame>.Continuation!
        let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(8)) {
            continuation = $0
        }
        videoFrameStream = stream
        videoContinuation = continuation
        return stream
    }

    private func audioBufferStreamLocked() -> AsyncStream<CapturedAudioBuffer> {
        if let audioBufferStream {
            return audioBufferStream
        }
        var continuation: AsyncStream<CapturedAudioBuffer>.Continuation!
        let stream = AsyncStream<CapturedAudioBuffer>(bufferingPolicy: .bufferingNewest(32)) {
            continuation = $0
        }
        audioBufferStream = stream
        audioContinuation = continuation
        return stream
    }
}

private extension WindowCaptureEngine {
    func startCapture(
        windowWrapper: SCWindowWrapper,
        applicationWrapper: SCApplicationWrapper,
        displayWrapper: SCDisplayWrapper,
        outputScale: CGFloat,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?,
        audioChannelCount: Int?
    ) async throws {
        try await startCapture(
            window: windowWrapper.window,
            application: applicationWrapper.application,
            display: displayWrapper.display,
            outputScale: outputScale,
            onFrame: onFrame,
            onAudio: onAudio,
            audioChannelCount: audioChannelCount
        )
    }

    func startCapture(
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize?,
        sourceRect: CGRect?,
        destinationRect: CGRect? = nil,
        contentWindowID: WindowID? = nil,
        includedWindowWrappers: [SCWindowWrapper] = [],
        excludedWindowWrappers: [SCWindowWrapper] = [],
        showsCursor: Bool,
        onFrame: @escaping @Sendable (CapturedFrame) -> Void,
        onAudio: (@Sendable (CapturedAudioBuffer) -> Void)?,
        audioChannelCount: Int?
    ) async throws {
        try await startDisplayCapture(
            display: displayWrapper.display,
            resolution: resolution,
            sourceRect: sourceRect,
            destinationRect: destinationRect,
            contentWindowID: contentWindowID,
            includedWindows: includedWindowWrappers.map(\.window),
            excludedWindows: excludedWindowWrappers.map(\.window),
            showsCursor: showsCursor,
            onFrame: onFrame,
            onAudio: onAudio,
            audioChannelCount: audioChannelCount
        )
    }
}

private extension MirageHostCaptureSource {
    var logDescription: String {
        switch self {
        case let .display(displayID):
            "display(\(displayID.rawValue))"
        case let .window(windowID):
            "window(\(windowID))"
        case let .displayWindowSet(displayID, includedWindowIDs, excludedWindowIDs):
            "displayWindowSet(display=\(displayID.rawValue), included=\(includedWindowIDs), excluded=\(excludedWindowIDs))"
        }
    }
}
#endif
