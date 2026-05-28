//
//  MirageHostService+CaptureBenchmarkMeasurement.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

@MainActor
extension MirageHostService {
    /// Measures the prepared source window generation and capture cadence phase.
    func measureSourcePhase(
        stage: MirageHostCaptureBenchmarkStage,
        source: MirageHostCaptureBenchmarkResolvedSource,
        warmupDurationSeconds: Double,
        measurementDurationSeconds: Double,
        cadenceProbe: VirtualDisplayCadenceProbe,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        completedStageCount: Int,
        totalStageCount: Int,
        progressHandler: (@MainActor @Sendable (MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async throws -> MirageHostCaptureBenchmarkPhaseMeasurement {
        let captureConfiguration = MirageEncoderConfiguration.highQuality
            .withTargetFrameRate(stage.targetFrameRate)
            .withInternalOverrides(pixelFormat: .bgra8, colorSpace: .sRGB)
        let captureEngine = WindowCaptureEngine(
            configuration: captureConfiguration,
            capturePressureProfile: .tuned,
            latencyMode: .lowestLatency,
            captureFrameRate: stage.targetFrameRate,
            usesDisplayRefreshCadence: true
        )

        defer {
            source.sourceClock?.cancelMeasurement()
            cadenceProbe.cancelMeasurement()
        }

        do {
            try await captureEngine.startCapture(
                window: source.windowWrapper.window,
                application: source.applicationWrapper.application,
                display: source.displayWrapper.display,
                onFrame: { _ in }
            )

            _ = await captureEngine.waitForCaptureStartupReadiness(timeout: .seconds(1))
            let capturePolicy = await captureEngine.capturePolicySnapshot.benchmarkPolicy

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Measuring source \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: warmupDurationSeconds)

            let startupReadiness = await captureEngine.captureStartupReadiness
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness
            ) {
                throw MirageHostCaptureBenchmarkError.measurementInvalid(invalidReason)
            }

            let measurementStart = CFAbsoluteTimeGetCurrent()
            let measurementEnd = measurementStart + measurementDurationSeconds
            source.sourceClock?.beginMeasurement()
            cadenceProbe.beginMeasurement()
            let telemetryBaseline = await captureEngine.captureTelemetrySnapshot

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            let telemetryFinal = await captureEngine.captureTelemetrySnapshot
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

            await captureEngine.stopCapture()

            return MirageHostCaptureBenchmarkPhaseMeasurement(
                phase: phase,
                observedDisplayCadenceFPS: observedDisplayCadenceFPS,
                sourceGenerationFPS: sourceGenerationFPS,
                capturePolicy: capturePolicy
            )
        } catch {
            await captureEngine.stopCapture()
            throw error
        }
    }

    /// Measures display capture throughput and encode throughput for a benchmark stage.
    func measureDisplayAndEncodePhase(
        stage: MirageHostCaptureBenchmarkStage,
        displayWrapper: SCDisplayWrapper,
        resolution: CGSize,
        lowPowerEnabled: Bool,
        warmupDurationSeconds: Double,
        measurementDurationSeconds: Double,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        completedStageCount: Int,
        totalStageCount: Int,
        progressHandler: (@MainActor @Sendable (MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async throws -> MirageHostCaptureBenchmarkDisplayMeasurement {
        let measurementWindow = Locked<MirageHostCaptureBenchmarkMeasurementWindow?>(nil)
        let encodedFrameCount = Locked<UInt64>(0)
        let frameContinuation = Locked<AsyncStream<CapturedFrame>.Continuation?>(nil)

        var encoder: VideoEncoder?
        var captureEngine: WindowCaptureEngine?
        var encodeTask: Task<Void, Never>?

        let captureWidth = max(1, Int(resolution.width.rounded()))
        let captureHeight = max(1, Int(resolution.height.rounded()))

        func cleanupResources() async {
            measurementWindow.withLock { $0 = nil }
            frameContinuation.withLock {
                $0?.finish()
                $0 = nil
            }
            if let captureEngine {
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
            let stageEncoder = VideoEncoder(
                configuration: baseConfiguration,
                latencyMode: .lowestLatency,
                streamKind: .desktop,
                maximizePowerEfficiencyEnabled: lowPowerEnabled
            )
            encoder = stageEncoder
            try await stageEncoder.createSession(width: captureWidth, height: captureHeight)
            _ = try await stageEncoder.preheatWithFallback()

            let activePixelFormat = await stageEncoder.activePixelFormat
            let captureConfiguration = baseConfiguration.withInternalOverrides(
                pixelFormat: activePixelFormat
            )
            let stageCaptureEngine = WindowCaptureEngine(
                configuration: captureConfiguration,
                capturePressureProfile: .tuned,
                latencyMode: .lowestLatency,
                captureFrameRate: stage.targetFrameRate,
                usesDisplayRefreshCadence: true
            )
            captureEngine = stageCaptureEngine

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

            try await stageCaptureEngine.startDisplayCapture(
                display: displayWrapper.display,
                resolution: resolution,
                showsCursor: false,
                onFrame: { frame in
                    frameContinuation.read { $0 }?.yield(frame)
                }
            )

            _ = await stageCaptureEngine.waitForDisplayStartupReadiness(timeout: .seconds(1))
            let capturePolicy = await stageCaptureEngine.capturePolicySnapshot.benchmarkPolicy

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Measuring display capture \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: warmupDurationSeconds)

            let startupReadiness = await stageCaptureEngine.displayStartupReadiness
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
            let telemetryBaseline = await stageCaptureEngine.captureTelemetrySnapshot

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            measurementWindow.withLock { $0 = nil }
            let telemetryFinal = await stageCaptureEngine.captureTelemetrySnapshot
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
