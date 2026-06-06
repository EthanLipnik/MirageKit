//
//  MacOSHostAudioCaptureBackend.swift
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
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Live macOS implementation of direct host audio capture.
final class MacOSHostAudioCaptureBackend: @unchecked Sendable, MirageHostAudioCaptureBackend {
    private let captureContentProviderBackend: any MirageHostCaptureContentProviderBackend
    private let stateLock = NSLock()
    private let sampleQueue = DispatchQueue(label: "com.mirage.capture.direct-audio", qos: .utility)
    private var stream: SCStream?
    private var streamOutput: CaptureStreamOutput?
    private var isStarting = false
    private var audioBufferStream: AsyncStream<CapturedAudioBuffer>?
    private var audioContinuation: AsyncStream<CapturedAudioBuffer>.Continuation?

    init(
        captureContentProviderBackend: any MirageHostCaptureContentProviderBackend =
            MacOSHostCaptureContentProviderBackend()
    ) {
        self.captureContentProviderBackend = captureContentProviderBackend
    }

    func startAudioCapture(_ configuration: MirageHostAudioCaptureConfiguration) async throws {
        try reserveStart()
        do {
            let displayWrapper = try await resolveDisplayWrapper(for: configuration)
            let output = CaptureStreamOutput(
                onFrame: { _ in },
                onAudio: { [weak self] buffer in
                    self?.yield(buffer)
                },
                onCaptureStall: { _ in },
                tracksFrameStatus: false
            )
            output.stopWatchdogTimer()
            let streamConfig = Self.streamConfiguration(for: configuration)
            let newStream = SCStream(
                filter: SCContentFilter(display: displayWrapper.display, excludingWindows: []),
                configuration: streamConfig,
                delegate: nil
            )
            try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
            finishStart(stream: newStream, output: output)
            MirageLogger.capture(
                "Direct host audio capture started for display \(displayWrapper.display.displayID), " +
                    "sampleRate=\(Int(configuration.sampleRate.rounded()))Hz channels=\(configuration.channelCount)"
            )
        } catch {
            cancelStart()
            throw error
        }
    }

    func audioBuffers() -> AsyncStream<CapturedAudioBuffer> {
        stateLock.lock()
        defer { stateLock.unlock() }
        return audioBufferStreamLocked()
    }

    func stopAudioCapture() async {
        let stoppedState = takeStoppedState()
        stoppedState.output?.stopWatchdogTimer()
        if let stream = stoppedState.stream {
            do {
                try await stream.stopCapture()
            } catch {
                MirageLogger.debug(.host, "Failed stopping direct host audio capture: \(error)")
            }
        }
        stoppedState.continuation?.finish()
    }

    private static func streamConfiguration(
        for configuration: MirageHostAudioCaptureConfiguration
    ) -> SCStreamConfiguration {
        let streamConfig = SCStreamConfiguration()
        streamConfig.captureResolution = .best
        streamConfig.capturesAudio = true
        streamConfig.excludesCurrentProcessAudio = configuration.excludesCurrentProcessAudio
        streamConfig.sampleRate = Int(configuration.sampleRate.rounded())
        streamConfig.channelCount = configuration.channelCount
        streamConfig.showsCursor = false
        streamConfig.queueDepth = 3
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        return streamConfig
    }

    private func resolveDisplayWrapper(
        for configuration: MirageHostAudioCaptureConfiguration
    ) async throws -> SCDisplayWrapper {
        let content = try await captureContentProviderBackend.shareableContent()
        let displayID = CGDirectDisplayID(configuration.displayID?.rawValue ?? CGMainDisplayID())
        guard let displayWrapper = content.displayWrapper(for: displayID) else {
            throw MirageCore.MirageError.protocolError(
                "Unable to resolve display \(displayID) for direct host audio capture; available displays: \(content.displayIDs)"
            )
        }
        return displayWrapper
    }

    private func reserveStart() throws {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard stream == nil, !isStarting else {
            throw MirageCore.MirageError.protocolError("Direct host audio capture is already running")
        }
        isStarting = true
        _ = audioBufferStreamLocked()
    }

    private func finishStart(stream: SCStream, output: CaptureStreamOutput) {
        stateLock.lock()
        defer { stateLock.unlock() }
        self.stream = stream
        streamOutput = output
        isStarting = false
    }

    private func cancelStart() {
        stateLock.lock()
        defer { stateLock.unlock() }
        isStarting = false
    }

    private func takeStoppedState() -> (
        stream: SCStream?,
        output: CaptureStreamOutput?,
        continuation: AsyncStream<CapturedAudioBuffer>.Continuation?
    ) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let stoppedState = (
            stream: stream,
            output: streamOutput,
            continuation: audioContinuation
        )
        stream = nil
        streamOutput = nil
        isStarting = false
        audioBufferStream = nil
        audioContinuation = nil
        return stoppedState
    }

    private func yield(_ buffer: CapturedAudioBuffer) {
        stateLock.lock()
        let continuation = audioContinuation
        stateLock.unlock()
        continuation?.yield(buffer)
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
#endif
