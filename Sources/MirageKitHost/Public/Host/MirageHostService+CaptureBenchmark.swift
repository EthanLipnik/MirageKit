//
//  MirageHostService+CaptureBenchmark.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

private enum MirageHostCaptureBenchmarkError: LocalizedError {
    case noModesSelected
    case noStagesConfigured
    case hostBusy
    case displayBoundsUnavailable(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .noModesSelected:
            "Select at least one benchmark mode."
        case .noStagesConfigured:
            "Configure at least one benchmark stage."
        case .hostBusy:
            "Capture benchmarking is unavailable while clients or streams are active."
        case let .displayBoundsUnavailable(displayID):
            "Unable to resolve bounds for benchmark display \(displayID)."
        }
    }
}

private struct MirageHostCaptureBenchmarkMeasurementWindow {
    let startTime: CFAbsoluteTime
    let endTime: CFAbsoluteTime

    func contains(_ timestamp: CFAbsoluteTime) -> Bool {
        timestamp >= startTime && timestamp <= endTime
    }
}

private struct MirageHostCaptureBenchmarkPresentationCounter {
    var frameCount: UInt64 = 0
    var lastPresentationSeconds: Double?

    mutating func record(_ presentationTime: CMTime) {
        let presentationSeconds = CMTimeGetSeconds(presentationTime)
        guard presentationSeconds.isFinite, presentationSeconds >= 0 else {
            frameCount &+= 1
            return
        }
        if let lastPresentationSeconds,
           abs(presentationSeconds - lastPresentationSeconds) < 0.000_1 {
            return
        }
        self.lastPresentationSeconds = presentationSeconds
        frameCount &+= 1
    }
}

private struct MirageHostCaptureBenchmarkTelemetryDelta {
    let averageCallbackTimeMs: Double?
    let maximumCallbackTimeMs: Double?
    let cadenceDropCount: UInt64
    let poolDropCount: UInt64
    let inFlightDropCount: UInt64
    let admissionDropCount: UInt64
    let averageCopyTimeMs: Double?
    let maximumCopyTimeMs: Double?
    let copyFailureCount: UInt64
}

@MainActor
extension MirageHostService {
    @_spi(HostApp)
    public func runCaptureBenchmark(
        configuration: MirageHostCaptureBenchmarkConfiguration,
        prepareSourceWindow: @escaping @MainActor @Sendable (MirageHostCaptureBenchmarkWindowConfiguration) async throws -> Void,
        progressHandler: (@MainActor @Sendable (MirageHostCaptureBenchmarkProgress?) -> Void)? = nil
    ) async throws -> MirageHostCaptureBenchmarkReport {
        guard !configuration.modeSelections.isEmpty else {
            throw MirageHostCaptureBenchmarkError.noModesSelected
        }
        guard !configuration.stages.isEmpty else {
            throw MirageHostCaptureBenchmarkError.noStagesConfigured
        }
        guard connectedClients.isEmpty, activeStreams.isEmpty, !isDesktopStreamActive else {
            throw MirageHostCaptureBenchmarkError.hostBusy
        }

        let totalStageCount = configuration.modeSelections.count * configuration.stages.count
        var completedStageCount = 0
        var modeResults: [MirageHostCaptureBenchmarkModeResult] = []
        var didCancel = false

        for modeSelection in configuration.modeSelections {
            if Task.isCancelled {
                didCancel = true
                break
            }

            let lowPowerEnabled = modeSelection.lowPowerEnabled
            var stageResults: [MirageHostCaptureBenchmarkStageResult] = []

            for stage in configuration.stages {
                if Task.isCancelled {
                    didCancel = true
                    let cancelledStage = MirageHostCaptureBenchmarkStageResult(
                        stage: stage,
                        status: .cancelled,
                        failureDescription: "Benchmark cancelled before stage start."
                    )
                    stageResults.append(cancelledStage)
                    progressHandler?(
                        MirageHostCaptureBenchmarkProgress(
                            phase: .cancelled,
                            modeSelection: modeSelection,
                            stage: stage,
                            completedStageCount: completedStageCount,
                            totalStageCount: totalStageCount,
                            message: "Cancelled"
                        )
                    )
                    break
                }

                progressHandler?(
                    MirageHostCaptureBenchmarkProgress(
                        phase: .preparing,
                        modeSelection: modeSelection,
                        stage: stage,
                        completedStageCount: completedStageCount,
                        totalStageCount: totalStageCount,
                        message: "Preparing \(stage.title) in \(modeSelection.displayName)"
                    )
                )

                let result = await runCaptureBenchmarkStage(
                    stage: stage,
                    modeSelection: modeSelection,
                    lowPowerEnabled: lowPowerEnabled,
                    warmupDurationSeconds: configuration.warmupDurationSeconds,
                    measurementDurationSeconds: configuration.measurementDurationSeconds,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    prepareSourceWindow: prepareSourceWindow,
                    progressHandler: progressHandler
                )
                stageResults.append(result)
                completedStageCount += 1

                if !captureBenchmarkShouldContinue(after: result.status) {
                    didCancel = true
                    break
                }
            }

            modeResults.append(
                MirageHostCaptureBenchmarkModeResult(
                    modeSelection: modeSelection,
                    lowPowerModeEnabled: lowPowerEnabled,
                    stageResults: stageResults
                )
            )

            if didCancel {
                break
            }
        }

        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.benchmark)
        progressHandler?(nil)

        let advertisement = currentPeerAdvertisement
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "0"
        let buildVersion = Bundle.main.object(
            forInfoDictionaryKey: kCFBundleVersionKey as String
        ) as? String ?? "0"

        return MirageHostCaptureBenchmarkReport(
            machineID: advertisement.deviceID ?? hostID,
            hostName: serviceName,
            hardwareModelIdentifier: advertisement.modelIdentifier,
            hardwareMachineFamily: advertisement.machineFamily,
            appVersion: appVersion,
            buildVersion: buildVersion,
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            configuration: configuration,
            measuredAt: Date(),
            modeResults: modeResults,
            didCancel: didCancel
        )
    }

    private func runCaptureBenchmarkStage(
        stage: MirageHostCaptureBenchmarkStage,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        lowPowerEnabled: Bool,
        warmupDurationSeconds: Double,
        measurementDurationSeconds: Double,
        completedStageCount: Int,
        totalStageCount: Int,
        prepareSourceWindow: @escaping @MainActor @Sendable (MirageHostCaptureBenchmarkWindowConfiguration) async throws -> Void,
        progressHandler: (@MainActor @Sendable (MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async -> MirageHostCaptureBenchmarkStageResult {
        let measurementWindow = Locked<MirageHostCaptureBenchmarkMeasurementWindow?>(nil)
        let capturedFrameCount = Locked<UInt64>(0)
        let encodedFrameCount = Locked<UInt64>(0)
        let presentationCounter = Locked(MirageHostCaptureBenchmarkPresentationCounter())
        let frameContinuation = Locked<AsyncStream<CapturedFrame>.Continuation?>(nil)
        var encoder: VideoEncoder?
        var captureEngine: WindowCaptureEngine?
        var encodeTask: Task<Void, Never>?
        let sourceRuntime = MirageHostCaptureBenchmarkSourceRuntime()

        func cleanupStageResources() async {
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
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.benchmark)
            let displaySnapshot = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                .benchmark,
                resolution: stage.pixelSize,
                refreshRate: stage.refreshRate
            )

            let validationResult = captureBenchmarkDisplayValidationResult(
                requestedStage: stage,
                actualResolution: displaySnapshot.resolution,
                actualRefreshRate: displaySnapshot.refreshRate
            )

            let captureWidth: Int
            let captureHeight: Int

            switch validationResult {
            case .exact:
                captureWidth = stage.pixelWidth
                captureHeight = stage.pixelHeight
            case let .accepted(actualWidth, actualHeight):
                captureWidth = actualWidth
                captureHeight = actualHeight
            case let .invalid(reason):
                return MirageHostCaptureBenchmarkStageResult(
                    stage: stage,
                    status: .invalid,
                    actualPixelWidth: Int(displaySnapshot.resolution.width.rounded()),
                    actualPixelHeight: Int(displaySnapshot.resolution.height.rounded()),
                    observedDisplayRefreshRate: displaySnapshot.refreshRate,
                    invalidMeasurementReason: reason
                )
            }

            guard let displayBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() else {
                throw MirageHostCaptureBenchmarkError.displayBoundsUnavailable(displaySnapshot.displayID)
            }

            try Task.checkCancellation()

            let windowConfiguration = MirageHostCaptureBenchmarkWindowConfiguration(
                stage: stage,
                modeSelection: modeSelection,
                displayID: displaySnapshot.displayID,
                displayBounds: displayBounds,
                pixelSize: displaySnapshot.resolution,
                spaceID: displaySnapshot.spaceID,
                sourceRuntime: sourceRuntime
            )
            try await prepareSourceWindow(windowConfiguration)

            let scDisplayWrapper = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                displayID: displaySnapshot.displayID,
                maxAttempts: 12
            )

            let baseConfiguration = MirageEncoderConfiguration.highQuality
                .withTargetFrameRate(stage.targetFrameRate)
            let stageEncoder = VideoEncoder(
                configuration: baseConfiguration,
                latencyMode: .lowestLatency,
                performanceMode: .standard,
                streamKind: .desktop,
                maximizePowerEfficiencyEnabled: lowPowerEnabled
            )
            encoder = stageEncoder
            try await stageEncoder.createSession(width: captureWidth, height: captureHeight)
            _ = try await stageEncoder.preheatWithFallback()

            let activePixelFormat = await stageEncoder.getActivePixelFormat()
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

            await stageEncoder.startEncoding(
                onEncodedFrame: captureBenchmarkEncodedFrameHandler(
                    measurementWindow: measurementWindow,
                    encodedFrameCount: encodedFrameCount
                ),
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
                display: scDisplayWrapper.display,
                resolution: displaySnapshot.resolution,
                showsCursor: false,
                onFrame: { frame in
                    let now = CFAbsoluteTimeGetCurrent()
                    let shouldCount = measurementWindow.read { window in
                        window?.contains(now) ?? false
                    }
                    if shouldCount {
                        capturedFrameCount.withLock { $0 &+= 1 }
                        presentationCounter.withLock { counter in
                            counter.record(frame.presentationTime)
                        }
                    }
                    frameContinuation.read { $0 }?.yield(frame)
                }
            )

            let readiness = await stageCaptureEngine.waitForDisplayStartupReadiness(timeout: .seconds(1))
            if readiness == .blankOrSuspendedOnly {
                MirageLogger.host(
                    "Capture benchmark startup for \(stage.title) only observed blank/suspended samples; continuing measurement."
                )
            }

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .warmingUp,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Warming up \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: warmupDurationSeconds)

            let startupReadiness = await stageCaptureEngine.displayStartupReadiness()
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness,
                validateSourceCadence: false,
                targetFrameRate: stage.targetFrameRate
            ) {
                await cleanupStageResources()
                return MirageHostCaptureBenchmarkStageResult(
                    stage: stage,
                    status: .invalid,
                    actualPixelWidth: captureWidth,
                    actualPixelHeight: captureHeight,
                    observedDisplayRefreshRate: displaySnapshot.refreshRate,
                    invalidMeasurementReason: invalidReason
                )
            }

            let measurementStart = CFAbsoluteTimeGetCurrent()
            let measurementEnd = measurementStart + measurementDurationSeconds
            sourceRuntime.beginMeasurement()
            measurementWindow.withLock {
                $0 = MirageHostCaptureBenchmarkMeasurementWindow(
                    startTime: measurementStart,
                    endTime: measurementEnd
                )
            }
            let telemetryBaseline = await stageCaptureEngine.captureTelemetrySnapshot()

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .measuring,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Measuring \(stage.title)"
                )
            )
            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            measurementWindow.withLock { $0 = nil }
            let sourceMeasurement = sourceRuntime.completeMeasurement(
                durationSeconds: measurementDurationSeconds
            )
            let telemetryFinal = await stageCaptureEngine.captureTelemetrySnapshot()
            await cleanupStageResources()

            let measurementDuration = max(0.001, measurementEnd - measurementStart)
            let captureFPS = Double(capturedFrameCount.read { $0 }) / measurementDuration
            let capturePresentationFPS = Double(
                presentationCounter.read { $0.frameCount }
            ) / measurementDuration
            let encodeFPS = Double(encodedFrameCount.read { $0 }) / measurementDuration
            let effectiveFPS = min(capturePresentationFPS, encodeFPS)
            let sourceFPS = sourceMeasurement.observedFPS
            let invalidMeasurementReason = captureBenchmarkInvalidMeasurementReason(
                sourceFPS: sourceFPS,
                targetFrameRate: stage.targetFrameRate
            )
            let capabilityFPS: Double? = if invalidMeasurementReason == nil {
                captureBenchmarkValidatedCapabilityFPS(
                    sourceFPS: sourceFPS,
                    capturePresentationFPS: capturePresentationFPS,
                    encodeFPS: encodeFPS,
                    targetFrameRate: stage.targetFrameRate
                )
            } else {
                nil
            }
            let telemetryDelta = captureBenchmarkTelemetryDelta(
                baseline: telemetryBaseline,
                final: telemetryFinal
            )

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .completed,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount + 1,
                    totalStageCount: totalStageCount,
                    message: "\(stage.title) complete"
                )
            )

            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: invalidMeasurementReason == nil ? .completed : .invalid,
                actualPixelWidth: captureWidth,
                actualPixelHeight: captureHeight,
                observedDisplayRefreshRate: displaySnapshot.refreshRate,
                observedSourceFPS: sourceFPS,
                captureFPS: captureFPS,
                observedCapturePresentationFPS: capturePresentationFPS,
                encodeFPS: encodeFPS,
                effectiveFPS: effectiveFPS,
                validatedCapabilityFPS: capabilityFPS,
                averageEncodeTimeMs: await stageEncoder.getAverageEncodeTimeMs(),
                averageCaptureCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
                maximumCaptureCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
                averageCaptureCopyTimeMs: telemetryDelta.averageCopyTimeMs,
                maximumCaptureCopyTimeMs: telemetryDelta.maximumCopyTimeMs,
                cadenceDropCount: telemetryDelta.cadenceDropCount,
                poolDropCount: telemetryDelta.poolDropCount,
                inFlightDropCount: telemetryDelta.inFlightDropCount,
                admissionDropCount: telemetryDelta.admissionDropCount,
                copyFailureCount: telemetryDelta.copyFailureCount,
                invalidMeasurementReason: invalidMeasurementReason
            )
        } catch is CancellationError {
            sourceRuntime.cancelMeasurement()
            await cleanupStageResources()
            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: .cancelled,
                failureDescription: "Benchmark cancelled."
            )
        } catch {
            sourceRuntime.cancelMeasurement()
            await cleanupStageResources()
            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: .failed,
                failureDescription: error.localizedDescription
            )
        }
    }

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

private func captureBenchmarkTelemetryDelta(
    baseline: CaptureStreamOutput.TelemetrySnapshot?,
    final: CaptureStreamOutput.TelemetrySnapshot?
) -> MirageHostCaptureBenchmarkTelemetryDelta {
    let baselineCallbackTotal = baseline?.callbackDurationTotalMs ?? 0
    let finalCallbackTotal = final?.callbackDurationTotalMs ?? 0
    let baselineCallbackSamples = baseline?.callbackSampleCount ?? 0
    let finalCallbackSamples = final?.callbackSampleCount ?? 0
    let callbackSampleDelta = finalCallbackSamples >= baselineCallbackSamples
        ? finalCallbackSamples - baselineCallbackSamples
        : 0
    let callbackTotalDelta = max(0, finalCallbackTotal - baselineCallbackTotal)

    let baselineCopy = baseline?.copyTelemetry
    let finalCopy = final?.copyTelemetry
    let copySuccessDelta: UInt64 = {
        let start = baselineCopy?.copySuccesses ?? 0
        let end = finalCopy?.copySuccesses ?? 0
        return end >= start ? end - start : 0
    }()
    let copyDurationDelta = max(
        0,
        (finalCopy?.durationTotalMs ?? 0) - (baselineCopy?.durationTotalMs ?? 0)
    )
    let copyFailureDelta: UInt64 = {
        let start = baselineCopy?.copyFailures ?? 0
        let end = finalCopy?.copyFailures ?? 0
        return end >= start ? end - start : 0
    }()

    return MirageHostCaptureBenchmarkTelemetryDelta(
        averageCallbackTimeMs: callbackSampleDelta > 0
            ? callbackTotalDelta / Double(callbackSampleDelta)
            : nil,
        maximumCallbackTimeMs: final?.callbackDurationMaxMs,
        cadenceDropCount: subtractCounter(
            final?.cadenceDropCount ?? 0,
            baseline?.cadenceDropCount ?? 0
        ),
        poolDropCount: subtractCounter(
            final?.poolDropCount ?? 0,
            baseline?.poolDropCount ?? 0
        ),
        inFlightDropCount: subtractCounter(
            final?.inFlightDropCount ?? 0,
            baseline?.inFlightDropCount ?? 0
        ),
        admissionDropCount: subtractCounter(
            final?.admissionDropCount ?? 0,
            baseline?.admissionDropCount ?? 0
        ),
        averageCopyTimeMs: copySuccessDelta > 0
            ? copyDurationDelta / Double(copySuccessDelta)
            : nil,
        maximumCopyTimeMs: finalCopy?.durationMaxMs,
        copyFailureCount: copyFailureDelta
    )
}

private func subtractCounter(_ end: UInt64, _ start: UInt64) -> UInt64 {
    end >= start ? end - start : 0
}

private func captureBenchmarkEncodedFrameHandler(
    measurementWindow: Locked<MirageHostCaptureBenchmarkMeasurementWindow?>,
    encodedFrameCount: Locked<UInt64>
) -> @Sendable (Data, Bool, CMTime) -> Void {
    { _, _, _ in
        let now = CFAbsoluteTimeGetCurrent()
        let shouldCount = measurementWindow.read { window in
            window?.contains(now) ?? false
        }
        guard shouldCount else { return }
        encodedFrameCount.withLock { $0 &+= 1 }
    }
}
#endif
