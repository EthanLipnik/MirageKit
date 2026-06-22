//
//  MirageHostService+WarmupCapture.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/11/26.
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
import CoreGraphics
#if os(macOS)
@MainActor
public extension MirageHostService {
    /// Runs a short hidden display capture to flush any follow-on screen-recording prompts.
    func performScreenRecordingWarmupCapture(
        duration: Duration = .seconds(1),
        frameRate: Int = 60
    ) async throws {
        let display = try await findMainSCDisplayWithRetry(maxAttempts: 6, delayMs: 60)
        let captureEngine = platformCaptureEngineFactoryBackend.makeCaptureEngine(
            configuration: encoderConfig,
            capturePressureProfile: .baseline,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            captureFrameRate: max(1, frameRate),
            usesDisplayRefreshCadence: false
        )

        let captureSourceBackend = MacOSHostCaptureSourceBackend(
            captureEngineFactoryBackend: platformCaptureEngineFactoryBackend,
            captureContentProviderBackend: platformCaptureContentProviderBackend
        )
        do {
            try await captureSourceBackend.startCapture(
                MirageHostCaptureRequest(
                    source: .display(MirageHostDisplayID(display.display.displayID)),
                    configuration: MirageHostCaptureConfiguration(
                        logicalSize: CGSize(width: display.display.width, height: display.display.height),
                        captureResolution: nil,
                        showsCursor: false,
                        targetFrameRate: max(1, frameRate),
                        queueDepth: encoderConfig.captureQueueDepth ?? 1,
                        capturesAudio: false,
                        audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: false)
                    )
                ),
                using: captureEngine,
                onFrame: { _ in },
                onAudio: nil
            )
            try await Task.sleep(for: duration)
            await captureSourceBackend.stopCapture()
        } catch {
            await captureSourceBackend.stopCapture()
            throw error
        }
    }
}
#endif
