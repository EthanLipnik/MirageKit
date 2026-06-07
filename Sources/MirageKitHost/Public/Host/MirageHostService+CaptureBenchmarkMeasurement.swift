//
//  MirageHostService+CaptureBenchmarkMeasurement.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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
import Foundation

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    /// Measures the prepared source window generation and capture cadence phase.
    func measureSourcePhase(
        stage: MirageDiagnostics.MirageHostCaptureBenchmarkStage,
        source: MirageHostCaptureBenchmarkResolvedSource,
        warmupDurationSeconds: Double,
        measurementDurationSeconds: Double,
        cadenceProbe: VirtualDisplayCadenceProbe,
        modeSelection: MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection,
        completedStageCount: Int,
        totalStageCount: Int,
        progressHandler: (@MainActor @Sendable (MirageDiagnostics.MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async throws -> MirageHostCaptureBenchmarkPhaseMeasurement {
        let captureConfiguration = MirageEncoderConfiguration.highQuality
            .withTargetFrameRate(stage.targetFrameRate)
            .withInternalOverrides(pixelFormat: .bgra8, colorSpace: .sRGB)
        let captureEngine = platformCaptureEngineFactoryBackend.makeCaptureEngine(
            configuration: captureConfiguration,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            captureFrameRate: stage.targetFrameRate,
            usesDisplayRefreshCadence: true
        )
        let captureSourceBackend = MacOSHostCaptureSourceBackend(
            captureEngineFactoryBackend: platformCaptureEngineFactoryBackend,
            captureContentProviderBackend: platformCaptureContentProviderBackend
        )

        defer {
            source.sourceClock?.cancelMeasurement()
            cadenceProbe.cancelMeasurement()
        }

        do {
            try await captureSourceBackend.startCapture(
                MirageHostCaptureRequest(
                    source: .window(WindowID(source.windowWrapper.window.windowID)),
                    configuration: MirageHostCaptureConfiguration(
                        logicalSize: source.windowWrapper.window.frame.size,
                        targetFrameRate: stage.targetFrameRate,
                        queueDepth: captureConfiguration.captureQueueDepth ?? 1,
                        capturesAudio: false,
                        audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: false)
                    )
                ),
                using: captureEngine,
                onFrame: { _ in },
                onAudio: nil
            )

            _ = await captureSourceBackend.waitForCaptureStartupReadiness(timeout: .seconds(1))
            guard let capturePolicySnapshot = await captureSourceBackend.capturePolicySnapshot() else {
                throw MirageCore.MirageError.protocolError("Benchmark capture source backend missing policy snapshot")
            }
            let capturePolicy = capturePolicySnapshot.benchmarkPolicy

            progressHandler?(
                MirageDiagnostics.MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Measuring source \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: warmupDurationSeconds)

            let startupReadiness = await captureSourceBackend.captureStartupReadiness()
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness
            ) {
                throw MirageHostCaptureBenchmarkError.measurementInvalid(invalidReason)
            }

            let measurementStart = CFAbsoluteTimeGetCurrent()
            let measurementEnd = measurementStart + measurementDurationSeconds
            source.sourceClock?.beginMeasurement()
            cadenceProbe.beginMeasurement()
            let telemetryBaseline = await captureSourceBackend.captureTelemetrySnapshot()

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            let telemetryFinal = await captureSourceBackend.captureTelemetrySnapshot()
            let observedDisplayCadenceFPS = cadenceProbe.completeMeasurement(
                durationSeconds: measurementDurationSeconds
            )
            let sourceGenerationFPS = source.sourceClock?.completeMeasurement(
                durationSeconds: measurementDurationSeconds
            )

            let measurementDuration = max(0.001, measurementEnd - measurementStart)
            let telemetryDelta = captureBenchmarkTelemetryDelta(
                baseline: telemetryBaseline,
                final: telemetryFinal
            )
            let phase = captureBenchmarkPhaseResult(
                kind: .source,
                telemetryDelta: telemetryDelta,
                startupReadiness: startupReadiness,
                measurementDuration: measurementDuration
            )

            await captureSourceBackend.stopCapture()

            return MirageHostCaptureBenchmarkPhaseMeasurement(
                phase: phase,
                observedDisplayCadenceFPS: observedDisplayCadenceFPS,
                sourceGenerationFPS: sourceGenerationFPS,
                capturePolicy: capturePolicy
            )
        } catch {
            await captureSourceBackend.stopCapture()
            throw error
        }
    }

    /// Measures display capture throughput and encode throughput for a benchmark stage.
    func measureDisplayAndEncodePhase(
        stage: MirageDiagnostics.MirageHostCaptureBenchmarkStage,
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize,
        lowPowerEnabled: Bool,
        warmupDurationSeconds: Double,
        measurementDurationSeconds: Double,
        modeSelection: MirageDiagnostics.MirageHostCaptureBenchmarkModeSelection,
        completedStageCount: Int,
        totalStageCount: Int,
        progressHandler: (@MainActor @Sendable (MirageDiagnostics.MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async throws -> MirageHostCaptureBenchmarkDisplayMeasurement {
        let measurementWindow = Locked<MirageHostCaptureBenchmarkMeasurementWindow?>(nil)
        let encodedFrameCount = Locked<UInt64>(0)
        let frameContinuation = Locked<AsyncStream<CapturedFrame>.Continuation?>(nil)

        var encoder: VideoEncoder?
        var captureEngine: WindowCaptureEngine?
        var captureSourceBackend: MacOSHostCaptureSourceBackend?
        var encodeTask: Task<Void, Never>?

        let captureWidth = max(1, Int(resolution.width.rounded()))
        let captureHeight = max(1, Int(resolution.height.rounded()))

        func cleanupResources() async {
            measurementWindow.withLock { $0 = nil }
            frameContinuation.withLock {
                $0?.finish()
                $0 = nil
            }
            if let captureSourceBackend {
                await captureSourceBackend.stopCapture()
            } else if let captureEngine {
                await captureEngine.stopCapture()
            }
            if let encodeTask {
                _ = await encodeTask.result
            }
            if let encoder {
                await encoder.stopEncoding()
            }
        }

        do {
            let baseConfiguration = MirageEncoderConfiguration.highQuality
                .withTargetFrameRate(stage.targetFrameRate)
            let stageEncoder = platformVideoEncoderFactoryBackend.makeVideoEncoder(
                configuration: baseConfiguration,
                latencyMode: .lowestLatency,
                streamKind: .desktop,
                mediaPathProfile: .unknown,
                inFlightLimit: nil,
                maximizePowerEfficiencyEnabled: lowPowerEnabled
            )
            encoder = stageEncoder
            try await stageEncoder.createSession(width: captureWidth, height: captureHeight)
            _ = try await stageEncoder.preheatWithFallback()

            let activePixelFormat = await stageEncoder.activePixelFormat
            let captureConfiguration = baseConfiguration.withInternalOverrides(
                pixelFormat: activePixelFormat
            )
            let stageCaptureEngine = platformCaptureEngineFactoryBackend.makeCaptureEngine(
                configuration: captureConfiguration,
                capturePressureProfile: .tuned,
                latencyMode: .lowestLatency,
                hostBufferingPolicy: .freshestFrame,
                captureFrameRate: stage.targetFrameRate,
                usesDisplayRefreshCadence: true
            )
            captureEngine = stageCaptureEngine
            let stageCaptureSourceBackend = MacOSHostCaptureSourceBackend(
                captureEngineFactoryBackend: platformCaptureEngineFactoryBackend,
                captureContentProviderBackend: platformCaptureContentProviderBackend
            )
            captureSourceBackend = stageCaptureSourceBackend

            let stream = AsyncStream<CapturedFrame>(bufferingPolicy: .bufferingNewest(1)) { continuation in
                frameContinuation.withLock { $0 = continuation }
            }

            let encodedFrameHandler = captureBenchmarkEncodedFrameHandler(
                measurementWindow: measurementWindow,
                encodedFrameCount: encodedFrameCount
            )
            await stageEncoder.startEncoding(
                onEncodedFrame: { data, isKeyframe, presentationTime, finishFrame in
                    encodedFrameHandler(data, isKeyframe, presentationTime)
                    finishFrame()
                },
                onFrameComplete: {}
            )

            encodeTask = Task(priority: .userInitiated) {
                for await frame in stream {
                    if Task.isCancelled { break }
                    do {
                        _ = try await stageEncoder.encodeFrame(frame)
                    } catch {
                        MirageLogger.error(.host, "Benchmark frame encode failed: \(error)")
                    }
                }
            }

            try await stageCaptureSourceBackend.startCapture(
                MirageHostCaptureRequest(
                    source: .display(MirageHostDisplayID(displayWrapper.display.displayID)),
                    configuration: MirageHostCaptureConfiguration(
                        logicalSize: resolution,
                        captureResolution: resolution,
                        showsCursor: false,
                        targetFrameRate: stage.targetFrameRate,
                        queueDepth: captureConfiguration.captureQueueDepth ?? 1,
                        capturesAudio: false,
                        audioConfiguration: MirageMedia.MirageAudioConfiguration(enabled: false)
                    )
                ),
                using: stageCaptureEngine,
                onFrame: { frame in
                    frameContinuation.read { $0 }?.yield(frame)
                },
                onAudio: nil
            )

            _ = await stageCaptureSourceBackend.waitForDisplayStartupReadiness(timeout: .seconds(1))
            guard let capturePolicySnapshot = await stageCaptureSourceBackend.capturePolicySnapshot() else {
                throw MirageCore.MirageError.protocolError("Benchmark display capture source backend missing policy snapshot")
            }
            let capturePolicy = capturePolicySnapshot.benchmarkPolicy

            progressHandler?(
                MirageDiagnostics.MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Measuring display capture \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: warmupDurationSeconds)

            let startupReadiness = await stageCaptureSourceBackend.displayStartupReadiness()
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness
            ) {
                throw MirageHostCaptureBenchmarkError.measurementInvalid(invalidReason)
            }

            let measurementStart = CFAbsoluteTimeGetCurrent()
            let measurementEnd = measurementStart + measurementDurationSeconds
            measurementWindow.withLock {
                $0 = MirageHostCaptureBenchmarkMeasurementWindow(
                    startTime: measurementStart,
                    endTime: measurementEnd
                )
            }
            let telemetryBaseline = await stageCaptureSourceBackend.captureTelemetrySnapshot()

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            measurementWindow.withLock { $0 = nil }
            let telemetryFinal = await stageCaptureSourceBackend.captureTelemetrySnapshot()
            let averageEncodeTimeMs = await stageEncoder.averageEncodeTimeMs

            let measurementDuration = max(0.001, measurementEnd - measurementStart)
            let telemetryDelta = captureBenchmarkTelemetryDelta(
                baseline: telemetryBaseline,
                final: telemetryFinal
            )
            let phase = captureBenchmarkPhaseResult(
                kind: .display,
                telemetryDelta: telemetryDelta,
                startupReadiness: startupReadiness,
                measurementDuration: measurementDuration
            )
            let encodeFPS = Double(encodedFrameCount.read { $0 }) / measurementDuration

            await cleanupResources()

            return MirageHostCaptureBenchmarkDisplayMeasurement(
                phase: phase,
                encodeFPS: encodeFPS,
                averageEncodeTimeMs: averageEncodeTimeMs,
                capturePolicy: capturePolicy
            )
        } catch {
            await cleanupResources()
            throw error
        }
    }

    /// Sleeps in short intervals so benchmark cancellation is observed promptly.
    private func sleepForBenchmark(durationSeconds: Double) async throws {
        guard durationSeconds > 0 else { return }
        let deadline = ContinuousClock.now + .milliseconds(
            Int64((durationSeconds * 1000).rounded())
        )
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let remaining = deadline - ContinuousClock.now
            let sleepDuration = min(remaining, .milliseconds(100))
            try await Task.sleep(for: sleepDuration)
        }
    }
}
#endif
