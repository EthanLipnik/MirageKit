//
//  MacOSHostCaptureSourceBackendTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import Foundation
import MirageKit
@testable import MirageKitHost
import Testing
import MirageCore
import MirageMedia

@Suite("macOS Host Capture Source Backend")
struct MacOSHostCaptureSourceBackendTests {
    @Test("macOS capture source backend resolves through capture content provider")
    func macOSCaptureSourceBackendResolvesThroughCaptureContentProvider() async throws {
        let backend = MacOSHostCaptureSourceBackend(
            captureEngineFactoryBackend: RecordingCaptureEngineFactoryBackend(),
            captureContentProviderBackend: FailingCaptureContentProviderBackend()
        )
        let frames = backend.videoFrames()
        let audioBuffers = backend.audioBuffers()

        await #expect(throws: CaptureSourceContentProviderError.unavailable) {
            try await backend.startCapture(Self.displayRequest())
        }
        await backend.stopCapture()

        #expect(await frames.finishesImmediately())
        #expect(await audioBuffers.finishesImmediately())
    }

    @Test("macOS capture source backend rejects concurrent starts")
    func macOSCaptureSourceBackendRejectsConcurrentStarts() async throws {
        let provider = SuspendedCaptureContentProviderBackend()
        let backend = MacOSHostCaptureSourceBackend(
            captureEngineFactoryBackend: RecordingCaptureEngineFactoryBackend(),
            captureContentProviderBackend: provider
        )

        let firstStart = Task {
            try await backend.startCapture(Self.displayRequest())
        }
        try await provider.waitUntilRequested()

        await #expect(throws: MirageCore.MirageError.self) {
            try await backend.startCapture(Self.displayRequest())
        }
        await backend.stopCapture()
        firstStart.cancel()
        do {
            try await firstStart.value
            Issue.record("Expected canceled capture start to throw")
        } catch {}
    }

    private static func displayRequest() -> MirageHostCaptureRequest {
        MirageHostCaptureRequest(
            source: .display(MirageHostDisplayID(42)),
            configuration: MirageHostCaptureConfiguration(
                logicalSize: CGSize(width: 1920, height: 1080),
                targetFrameRate: 0,
                queueDepth: 0,
                capturesAudio: true,
                audioConfiguration: MirageMedia.MirageAudioConfiguration(
                    enabled: true,
                    channelLayout: .stereo,
                    quality: .lossless
                )
            )
        )
    }
}

private enum CaptureSourceContentProviderError: Error, Equatable {
    case unavailable
}

private struct FailingCaptureContentProviderBackend: MirageHostCaptureContentProviderBackend {
    func shareableContent() async throws -> SCShareableContentWrapper {
        throw CaptureSourceContentProviderError.unavailable
    }
}

private actor SuspendedCaptureContentProviderBackend: MirageHostCaptureContentProviderBackend {
    private var requested = false

    func shareableContent() async throws -> SCShareableContentWrapper {
        requested = true
        while !Task.isCancelled {
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func waitUntilRequested() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if requested { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for capture content provider request")
        throw CancellationError()
    }
}

private struct RecordingCaptureEngineFactoryBackend: MirageHostCaptureEngineFactoryBackend {
    func makeCaptureEngine(
        configuration: MirageEncoderConfiguration,
        capturePressureProfile: WindowCaptureEngine.CapturePressureProfile,
        latencyMode: MirageMedia.MirageStreamLatencyMode,
        hostBufferingPolicy: MirageMedia.MirageHostBufferingPolicy,
        captureFrameRate: Int?,
        usesDisplayRefreshCadence: Bool
    ) -> WindowCaptureEngine {
        WindowCaptureEngine(
            configuration: configuration,
            capturePressureProfile: capturePressureProfile,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            captureFrameRate: captureFrameRate,
            usesDisplayRefreshCadence: usesDisplayRefreshCadence
        )
    }
}

private extension AsyncStream {
    func finishesImmediately() async -> Bool {
        var iterator = makeAsyncIterator()
        return await iterator.next() == nil
    }
}
#endif
