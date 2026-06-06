//
//  MirageHostPlatformBackendTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

#if os(macOS)
import CoreGraphics
import CoreMedia
import Foundation
import MirageKit
@testable import MirageKitHost
import Testing
import MirageCore
import MirageInput
import MirageMedia
import MirageWire

@Suite("Mirage Host Platform Backend")
struct MirageHostPlatformBackendTests {
    @MainActor
    @Test("Host service refreshes and activates windows through platform backend")
    func hostServiceRefreshesAndActivatesWindowsThroughPlatformBackend() async throws {
        let window = Self.window(id: 900, title: "Backend Window")
        let backend = RecordingWindowCatalogBackend(windows: [window])
        let service = MirageHostService(
            hostName: "Platform Backend Host",
            deviceID: UUID()
        )
        service.platformWindowCatalogBackend = backend

        try await service.refreshWindows()
        await service.activateWindow(window)

        #expect(service.availableWindows.map(\.id) == [900])
        #expect(service.availableWindows.first?.title == "Backend Window")
        #expect(await backend.refreshWindowsCallCount() == 1)
        #expect(await backend.activatedWindowIDs() == [900])
    }

    @MainActor
    @Test("Host service dispatches fast input through platform backend")
    func hostServiceDispatchesFastInputThroughPlatformBackend() async throws {
        let window = Self.window(id: 901, title: "Input Window")
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Test Client",
            deviceType: .iPad,
            connectedAt: Date()
        )
        let sessionID = UUID()
        let backend = RecordingInputInjectionBackend()
        let service = MirageHostService(
            hostName: "Platform Input Host",
            deviceID: UUID()
        )
        service.platformInputInjectionBackend = backend
        service.streamRegistry.registerInputSession(sessionID, clientID: client.id)
        service.inputStreamCache.set(41, window: window, client: client)

        let event = MirageInput.MirageInputEvent.mouseMoved(MirageInput.MirageMouseEvent(location: CGPoint(x: 0.25, y: 0.75)))
        let inputMessage = MirageWire.InputEventMessage(streamID: 41, event: event)
        let controlMessage = MirageWire.ControlMessage(type: .inputEvent, payload: try inputMessage.serializePayload())

        service.handleInputEventFast(controlMessage, from: client, sessionID: sessionID)
        let injection = try await backend.waitForFirstInjection()

        #expect(injection.windowID == 901)
        #expect(injection.validatorAcceptedRoute)
        guard case let .mouseMoved(mouseEvent) = injection.event else {
            Issue.record("Expected mouseMoved event to reach input backend")
            return
        }
        #expect(mouseEvent.location == CGPoint(x: 0.25, y: 0.75))
    }

    @Test("macOS video encoder factory preserves runtime configuration")
    func macOSVideoEncoderFactoryPreservesRuntimeConfiguration() async throws {
        let configuration = MirageEncoderConfiguration.highQuality
            .withTargetFrameRate(144)
            .withInternalOverrides(pixelFormat: .bgra8)
        let encoder = MacOSHostVideoEncoderFactoryBackend().makeVideoEncoder(
            configuration: configuration,
            latencyMode: .smoothest,
            streamKind: .appAtlas,
            mediaPathProfile: .unknown,
            inFlightLimit: 3,
            maximizePowerEfficiencyEnabled: true
        )

        #expect(await encoder.configuration.targetFrameRate == 144)
        #expect(await encoder.activePixelFormat == .bgra8)
        #expect(await encoder.latencyMode == .smoothest)
        #expect(await encoder.streamKind == .appAtlas)
        #expect(await encoder.mediaPathProfile == .unknown)
        #expect(encoder.encoderInFlightLimit == 3)
        #expect(await encoder.maximizePowerEfficiencyEnabled)
    }

    @Test("macOS capture engine factory preserves runtime configuration")
    func macOSCaptureEngineFactoryPreservesRuntimeConfiguration() async throws {
        let configuration = MirageEncoderConfiguration.highQuality
            .withTargetFrameRate(72)
            .withInternalOverrides(pixelFormat: .bgra8)
        let captureEngine = MacOSHostCaptureEngineFactoryBackend().makeCaptureEngine(
            configuration: configuration,
            capturePressureProfile: .tuned,
            latencyMode: .smoothest,
            hostBufferingPolicy: .stability,
            captureFrameRate: 48,
            usesDisplayRefreshCadence: true
        )

        #expect(await captureEngine.configuration.targetFrameRate == 72)
        #expect(await captureEngine.configuration.pixelFormat == .bgra8)
        #expect(await captureEngine.capturePressureProfile == .tuned)
        #expect(await captureEngine.latencyMode == .smoothest)
        #expect(await captureEngine.hostBufferingPolicy == .stability)
        #expect(await captureEngine.currentFrameRate == 48)
        #expect(await captureEngine.usesDisplayRefreshCadence)
    }

    @Test("macOS audio pipeline factory emits packets for captured audio")
    func macOSAudioPipelineFactoryEmitsPacketsForCapturedAudio() async throws {
        let recorder = RecordingAudioPacketSink()
        let pipeline = MacOSHostAudioPipelineFactoryBackend().makeAudioPipeline(
            sourceStreamID: 77,
            audioConfiguration: MirageMedia.MirageAudioConfiguration(
                enabled: true,
                channelLayout: .stereo,
                quality: .lossless
            ),
            transportPathKind: .unknown,
            mediaPathProfile: .unknown,
            maxPayloadSize: 512,
            mediaSecurityContext: nil,
            onPacketsReady: { packets, encoded, streamID in
                await recorder.record(
                    AudioPacketDelivery(
                        packetCount: packets.count,
                        codec: encoded.codec,
                        streamID: streamID
                    )
                )
            }
        )

        await pipeline.enqueue(Self.audioBuffer())
        let delivery = try await recorder.waitForDelivery()
        await pipeline.stop()

        #expect(delivery.streamID == 77)
        #expect(delivery.codec == .pcm16LE)
        #expect(delivery.packetCount > 0)
    }

    @Test("macOS audio capture backend resolves through capture content provider")
    func macOSAudioCaptureBackendResolvesThroughCaptureContentProvider() async throws {
        let backend = MacOSHostAudioCaptureBackend(captureContentProviderBackend: FakeCaptureContentProviderBackend())
        let buffers = backend.audioBuffers()
        let configuration = MirageHostAudioCaptureConfiguration(sampleRate: 0, channelCount: 0, excludesCurrentProcessAudio: true, displayID: MirageHostDisplayID(42))

        await #expect(throws: FakeCaptureContentProviderError.unavailable) {
            try await backend.startAudioCapture(configuration)
        }
        await backend.stopAudioCapture()

        #expect(await buffers.finishesImmediately())
    }

    private static func audioBuffer() -> CapturedAudioBuffer {
        CapturedAudioBuffer(
            data: Data(count: 4_800 * 2 * MemoryLayout<Float>.size),
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 4_800,
            bitsPerChannel: 32,
            isFloat: true,
            isInterleaved: true,
            presentationTime: CMTime(seconds: 1, preferredTimescale: 1_000_000_000)
        )
    }

    @Test("Host platform backend contracts compose fake macOS backends")
    func hostPlatformBackendContractsComposeFakeMacOSBackends() async throws {
        let backend = MirageHostPlatformBackend(
            captureSource: FakeCaptureSourceBackend(),
            windowCatalog: FakeWindowCatalogBackend(),
            encoder: FakeEncoderBackend(),
            inputInjection: FakeInputInjectionBackend(),
            audioCapture: FakeAudioCaptureBackend()
        )
        let captureRequest = MirageHostCaptureRequest(
            source: .displayWindowSet(
                displayID: MirageHostDisplayID(42),
                includedWindowIDs: [7],
                excludedWindowIDs: [9]
            ),
            configuration: MirageHostCaptureConfiguration(
                logicalSize: CGSize(width: 1920, height: 1080),
                targetFrameRate: 0,
                queueDepth: 0,
                capturesAudio: true
            )
        )

        try await backend.captureSource.startCapture(captureRequest)
        let applications = try await backend.windowCatalog.refreshApplications()
        let windows = try await backend.windowCatalog.refreshWindows()
        try await backend.windowCatalog.activateApplication(applications[0])
        try await backend.windowCatalog.activateWindow(windows[0])
        try await backend.encoder.configure(
            MirageHostEncoderConfiguration(
                codec: .hevc,
                colorDepth: .standard,
                targetFrameRate: 0,
                bitrateBps: 0,
                maximumInFlightFrames: 0,
                rateControlStrategy: .averageBitRateDataRateLimits,
                lowPowerModeEnabled: false
            )
        )
        let encoded = try await backend.encoder.encode(1, forceKeyframe: true)
        try await backend.inputInjection.inject(
            .mouseDown(MirageInput.MirageMouseEvent(location: CGPoint(x: 0.5, y: 0.5))),
            target: .window(windows[0])
        )
        try await backend.inputInjection.performSystemAction(
            MirageInput.MirageHostSystemActionRequest(action: .missionControl)
        )
        let closeResult = try await backend.inputInjection.closeWindow(windows[0])
        guard case .notClosed = closeResult else {
            Issue.record("Expected fake input backend to report notClosed")
            return
        }
        #expect(try await backend.inputInjection.pressBlockingAlertAction(
            in: windows[0],
            actionIndex: 0,
            fallbackTitle: "Close"
        ))
        try await backend.audioCapture.startAudioCapture(
            MirageHostAudioCaptureConfiguration(
                sampleRate: 0,
                channelCount: 0,
                excludesCurrentProcessAudio: true
            )
        )

        #expect(captureRequest.source.windowIDs == [7, 9])
        #expect(captureRequest.configuration.targetFrameRate == 1)
        #expect(captureRequest.configuration.queueDepth == 1)
        #expect(applications.map(\.name) == ["Fake App"])
        #expect(windows.map(\.id) == [7])
        #expect(encoded.streamID == 1)
        #expect(encoded.isEmpty)
        let captureContentProvider: any MirageHostCaptureContentProviderBackend = FakeCaptureContentProviderBackend()
        await #expect(throws: FakeCaptureContentProviderError.unavailable) {
            try await captureContentProvider.shareableContent()
        }
        #expect(await FakeCaptureSourceBackend().videoFrames().finishesImmediately())
        #expect(await FakeAudioCaptureBackend().audioBuffers().finishesImmediately())
    }

    private static func window(id: WindowID, title: String) -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: id,
            title: title,
            application: MirageMedia.MirageApplication(
                id: 123,
                bundleIdentifier: "com.example.fake",
                name: "Fake App"
            ),
            frame: CGRect(x: 10, y: 20, width: 640, height: 480),
            isOnScreen: true,
            windowLayer: 0
        )
    }
}

private actor RecordingWindowCatalogBackend: MirageHostWindowCatalogBackend {
    private let windows: [MirageMedia.MirageWindow]
    private var refreshWindowsCalls = 0

    init(windows: [MirageMedia.MirageWindow]) {
        self.windows = windows
    }

    func refreshApplications() async throws -> [MirageMedia.MirageApplication] {
        windows.compactMap(\.application)
    }

    func refreshWindows() async throws -> [MirageMedia.MirageWindow] {
        refreshWindowsCalls += 1
        return windows
    }

    func windows(forApplicationWithBundleIdentifier bundleIdentifier: String) async throws -> [MirageMedia.MirageWindow] {
        windows.filter { $0.application?.bundleIdentifier == bundleIdentifier }
    }

    func activateApplication(_: MirageMedia.MirageApplication) async throws {}

    func activateWindow(_ window: MirageMedia.MirageWindow) async throws {
        activatedWindows.append(window.id)
    }

    func refreshWindowsCallCount() -> Int {
        refreshWindowsCalls
    }

    func activatedWindowIDs() -> [WindowID] {
        activatedWindows
    }

    private var activatedWindows: [WindowID] = []
}

private actor RecordingInputInjectionBackend: MirageHostInputInjectionBackend {
    struct Injection {
        let event: MirageInput.MirageInputEvent
        let windowID: WindowID
        let validatorAcceptedRoute: Bool
    }

    private var injections: [Injection] = []

    func inject(
        _ event: MirageInput.MirageInputEvent,
        target: MirageHostInputTarget,
        deferredInjectionValidator: (@Sendable () -> Bool)?
    ) async throws {
        guard case let .window(window) = target else { return }
        injections.append(Injection(
            event: event,
            windowID: window.id,
            validatorAcceptedRoute: deferredInjectionValidator?() ?? true
        ))
    }

    func performSystemAction(_: MirageInput.MirageHostSystemActionRequest) async throws {}

    func closeWindow(_: MirageMedia.MirageWindow) async throws -> HostWindowCloseAttemptResult {
        .notClosed
    }

    func pressBlockingAlertAction(
        in _: MirageMedia.MirageWindow,
        actionIndex _: Int,
        fallbackTitle _: String
    ) async throws -> Bool {
        true
    }

    func waitForFirstInjection() async throws -> Injection {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if let injection = injections.first {
                return injection
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for input backend injection")
        throw CancellationError()
    }
}

private struct AudioPacketDelivery: Sendable {
    let packetCount: Int
    let codec: MirageMedia.MirageAudioCodec
    let streamID: StreamID
}

private actor RecordingAudioPacketSink {
    private var deliveries: [AudioPacketDelivery] = []

    func record(_ delivery: AudioPacketDelivery) {
        deliveries.append(delivery)
    }

    func waitForDelivery() async throws -> AudioPacketDelivery {
        let deadline = ContinuousClock.now + .seconds(1)
        while ContinuousClock.now < deadline {
            if let delivery = deliveries.first {
                return delivery
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for audio packets")
        throw CancellationError()
    }
}

private struct FakeCaptureSourceBackend: MirageHostCaptureSourceBackend {
    func startCapture(_: MirageHostCaptureRequest) async throws {}

    func videoFrames() -> AsyncStream<Int> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func audioBuffers() -> AsyncStream<String> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func stopCapture() async {}
}

private enum FakeCaptureContentProviderError: Error, Equatable {
    case unavailable
}

private struct FakeCaptureContentProviderBackend: MirageHostCaptureContentProviderBackend {
    func shareableContent() async throws -> SCShareableContentWrapper {
        throw FakeCaptureContentProviderError.unavailable
    }
}

private struct FakeWindowCatalogBackend: MirageHostWindowCatalogBackend {
    func refreshApplications() async throws -> [MirageMedia.MirageApplication] {
        [Self.application]
    }

    func refreshWindows() async throws -> [MirageMedia.MirageWindow] {
        [Self.window]
    }

    func windows(forApplicationWithBundleIdentifier _: String) async throws -> [MirageMedia.MirageWindow] {
        [Self.window]
    }

    func activateApplication(_: MirageMedia.MirageApplication) async throws {}

    func activateWindow(_: MirageMedia.MirageWindow) async throws {}

    private static let application = MirageMedia.MirageApplication(
        id: 123,
        bundleIdentifier: "com.example.fake",
        name: "Fake App"
    )

    private static let window = MirageMedia.MirageWindow(
        id: 7,
        title: "Fake Window",
        application: application,
        frame: CGRect(x: 10, y: 20, width: 640, height: 480),
        isOnScreen: true,
        windowLayer: 0
    )
}

private struct FakeEncoderBackend: MirageHostEncoderBackend {
    func configure(_: MirageHostEncoderConfiguration) async throws {}

    func encode(_: Int, forceKeyframe _: Bool) async throws -> MirageEncodedMediaBatch {
        let topology = MirageMediaTopology.singleUnit(
            logicalSize: MiragePixelSize(width: 1, height: 1),
            codec: .hevc
        )
        return MirageEncodedMediaBatch(streamID: 1, topologyID: topology.id, units: [])
    }

    func stopEncoding() async {}
}

private struct FakeInputInjectionBackend: MirageHostInputInjectionBackend {
    func inject(
        _: MirageInput.MirageInputEvent,
        target _: MirageHostInputTarget,
        deferredInjectionValidator _: (@Sendable () -> Bool)?
    ) async throws {}

    func performSystemAction(_: MirageInput.MirageHostSystemActionRequest) async throws {}

    func closeWindow(_: MirageMedia.MirageWindow) async throws -> HostWindowCloseAttemptResult { .notClosed }

    func pressBlockingAlertAction(
        in _: MirageMedia.MirageWindow,
        actionIndex _: Int,
        fallbackTitle _: String
    ) async throws -> Bool { true }
}

private struct FakeAudioCaptureBackend: MirageHostAudioCaptureBackend {
    func startAudioCapture(_: MirageHostAudioCaptureConfiguration) async throws {}

    func audioBuffers() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func stopAudioCapture() async {}
}

private extension AsyncStream {
    func finishesImmediately() async -> Bool {
        var iterator = makeAsyncIterator()
        return await iterator.next() == nil
    }
}
#endif
