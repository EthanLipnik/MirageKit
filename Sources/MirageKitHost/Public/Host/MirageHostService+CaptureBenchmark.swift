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
    case measurementInvalid(String)

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
        case let .measurementInvalid(reason):
            reason
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

private struct MirageHostCaptureBenchmarkResolvedSource {
    let windowWrapper: SCWindowWrapper
    let applicationWrapper: SCApplicationWrapper
    let displayWrapper: SCDisplayWrapper
}

private struct MirageHostCaptureBenchmarkPhaseMeasurement {
    let phase: MirageHostCaptureBenchmarkPhaseResult
    let observedDisplayCadenceFPS: Double?
}

private struct MirageHostCaptureBenchmarkDisplayMeasurement {
    let phase: MirageHostCaptureBenchmarkPhaseResult
    let encodeFPS: Double?
    let averageEncodeTimeMs: Double?
}

@MainActor
extension MirageHostService {
    @_spi(HostApp)
    public func runCaptureBenchmark(
        configuration: MirageHostCaptureBenchmarkConfiguration,
        prepareSourceWindow: @escaping @MainActor @Sendable (MirageHostCaptureBenchmarkWindowConfiguration) async throws -> MirageHostCaptureBenchmarkPreparedSource,
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
                    stageResults.append(
                        MirageHostCaptureBenchmarkStageResult(
                            stage: stage,
                            status: .cancelled,
                            failureDescription: "Benchmark cancelled before stage start."
                        )
                    )
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
        prepareSourceWindow: @escaping @MainActor @Sendable (MirageHostCaptureBenchmarkWindowConfiguration) async throws -> MirageHostCaptureBenchmarkPreparedSource,
        progressHandler: (@MainActor @Sendable (MirageHostCaptureBenchmarkProgress?) -> Void)?
    ) async -> MirageHostCaptureBenchmarkStageResult {
        var actualPixelWidth: Int?
        var actualPixelHeight: Int?
        var reportedDisplayRefreshRate: Double?
        var stageWarnings: [MirageHostCaptureBenchmarkWarning] = []

        do {
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.benchmark)
            let displaySnapshot = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(
                .benchmark,
                resolution: stage.pixelSize,
                refreshRate: stage.refreshRate
            )

            reportedDisplayRefreshRate = displaySnapshot.refreshRate
            let validationResult = captureBenchmarkDisplayValidationResult(
                requestedStage: stage,
                actualResolution: displaySnapshot.resolution,
                actualRefreshRate: displaySnapshot.refreshRate
            )

            switch validationResult {
            case .exact:
                actualPixelWidth = stage.pixelWidth
                actualPixelHeight = stage.pixelHeight
            case let .accepted(actualWidth, actualHeight):
                actualPixelWidth = actualWidth
                actualPixelHeight = actualHeight
                stageWarnings.append(.quantizedResolution)
            case let .invalid(reason):
                return MirageHostCaptureBenchmarkStageResult(
                    stage: stage,
                    status: .invalid,
                    actualPixelWidth: Int(displaySnapshot.resolution.width.rounded()),
                    actualPixelHeight: Int(displaySnapshot.resolution.height.rounded()),
                    reportedDisplayRefreshRate: displaySnapshot.refreshRate,
                    invalidMeasurementReason: reason
                )
            }

            guard let displayBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() else {
                throw MirageHostCaptureBenchmarkError.displayBoundsUnavailable(displaySnapshot.displayID)
            }

            let windowConfiguration = MirageHostCaptureBenchmarkWindowConfiguration(
                stage: stage,
                modeSelection: modeSelection,
                displayID: displaySnapshot.displayID,
                displayBounds: displayBounds,
                pixelSize: displaySnapshot.resolution,
                spaceID: displaySnapshot.spaceID
            )

            let preparedSource: MirageHostCaptureBenchmarkPreparedSource
            do {
                preparedSource = try await prepareSourceWindow(windowConfiguration)
            } catch {
                throw MirageHostCaptureBenchmarkError.measurementInvalid(
                    "Failed to prepare benchmark source window: \(error.localizedDescription)"
                )
            }

            guard let cadenceProbe = VirtualDisplayCadenceProbe(displayID: displaySnapshot.displayID),
                  cadenceProbe.start() else {
                throw MirageHostCaptureBenchmarkError.measurementInvalid(
                    "Display cadence probe failed to attach to the benchmark display."
                )
            }
            defer {
                cadenceProbe.stop()
            }

            let resolvedSource = try await resolveBenchmarkSource(
                preparedSource,
                fallbackDisplayID: displaySnapshot.displayID
            )

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .warmingUp,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Warming up source \(stage.title)"
                )
            )
            let sourceMeasurement = try await measureSourcePhase(
                stage: stage,
                source: resolvedSource,
                warmupDurationSeconds: warmupDurationSeconds,
                measurementDurationSeconds: measurementDurationSeconds,
                cadenceProbe: cadenceProbe,
                modeSelection: modeSelection,
                completedStageCount: completedStageCount,
                totalStageCount: totalStageCount,
                progressHandler: progressHandler
            )

            progressHandler?(
                MirageHostCaptureBenchmarkProgress(
                    phase: .warmingUp,
                    modeSelection: modeSelection,
                    stage: stage,
                    completedStageCount: completedStageCount,
                    totalStageCount: totalStageCount,
                    message: "Warming up display capture \(stage.title)"
                )
            )

            let scDisplayWrapper = try await SharedVirtualDisplayManager.shared.findSCDisplay(
                displayID: displaySnapshot.displayID,
                maxAttempts: 12
            )
            let displayMeasurement = try await measureDisplayAndEncodePhase(
                stage: stage,
                displayWrapper: scDisplayWrapper,
                resolution: displaySnapshot.resolution,
                lowPowerEnabled: lowPowerEnabled,
                warmupDurationSeconds: warmupDurationSeconds,
                measurementDurationSeconds: measurementDurationSeconds,
                modeSelection: modeSelection,
                completedStageCount: completedStageCount,
                totalStageCount: totalStageCount,
                progressHandler: progressHandler
            )

            let sourcePhase = sourceMeasurement.phase
            let displayPhase = displayMeasurement.phase
            let encodeFPS = displayMeasurement.encodeFPS
            let observedDisplayCadenceFPS = sourceMeasurement.observedDisplayCadenceFPS

            stageWarnings = deduplicatedBenchmarkWarnings(
                stageWarnings +
                    captureBenchmarkWarnings(
                        stage: stage,
                        reportedDisplayRefreshRate: displaySnapshot.refreshRate,
                        observedDisplayCadenceFPS: observedDisplayCadenceFPS,
                        sourcePhase: sourcePhase,
                        displayPhase: displayPhase,
                        encodeFPS: encodeFPS
                    )
            )

            let displayCaptureCapabilityFPS = captureBenchmarkDisplayCapabilityFPS(
                displayPhase: displayPhase,
                targetFrameRate: stage.targetFrameRate
            )
            let validatedCapabilityFPS = captureBenchmarkValidatedCapabilityFPS(
                sourcePhase: sourcePhase,
                displayPhase: displayPhase,
                encodeFPS: encodeFPS,
                targetFrameRate: stage.targetFrameRate
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
                status: .completed,
                actualPixelWidth: actualPixelWidth,
                actualPixelHeight: actualPixelHeight,
                reportedDisplayRefreshRate: displaySnapshot.refreshRate,
                observedDisplayCadenceFPS: observedDisplayCadenceFPS,
                sourcePhase: sourcePhase,
                displayPhase: displayPhase,
                encodeFPS: encodeFPS,
                displayCaptureCapabilityFPS: displayCaptureCapabilityFPS,
                validatedCapabilityFPS: validatedCapabilityFPS,
                averageEncodeTimeMs: displayMeasurement.averageEncodeTimeMs,
                warnings: stageWarnings
            )
        } catch is CancellationError {
            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: .cancelled,
                actualPixelWidth: actualPixelWidth,
                actualPixelHeight: actualPixelHeight,
                reportedDisplayRefreshRate: reportedDisplayRefreshRate,
                warnings: stageWarnings,
                failureDescription: "Benchmark cancelled."
            )
        } catch let error as MirageHostCaptureBenchmarkError {
            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: .invalid,
                actualPixelWidth: actualPixelWidth,
                actualPixelHeight: actualPixelHeight,
                reportedDisplayRefreshRate: reportedDisplayRefreshRate,
                warnings: stageWarnings,
                invalidMeasurementReason: error.localizedDescription
            )
        } catch {
            return MirageHostCaptureBenchmarkStageResult(
                stage: stage,
                status: .failed,
                actualPixelWidth: actualPixelWidth,
                actualPixelHeight: actualPixelHeight,
                reportedDisplayRefreshRate: reportedDisplayRefreshRate,
                warnings: stageWarnings,
                failureDescription: error.localizedDescription
            )
        }
    }

    private func resolveBenchmarkSource(
        _ preparedSource: MirageHostCaptureBenchmarkPreparedSource,
        fallbackDisplayID: CGDirectDisplayID,
        maxAttempts: Int = 12,
        initialDelayMs: Int = 80
    ) async throws -> MirageHostCaptureBenchmarkResolvedSource {
        let attempts = max(1, maxAttempts)
        var delayMs = max(40, initialDelayMs)

        for attempt in 1 ... attempts {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )

                if let resolvedWindow = content.windows.first(where: { $0.windowID == preparedSource.windowID }),
                   let resolvedApplication = content.applications.first(where: {
                       $0.processID == preparedSource.applicationPID
                   }) ?? resolvedWindow.owningApplication,
                   let resolvedDisplay = content.displays.first(where: {
                       $0.displayID == preparedSource.displayID
                   }) ?? content.displays.first(where: {
                       $0.displayID == fallbackDisplayID
                   }) ?? resolveDisplayForBenchmarkSourceWindow(
                       resolvedWindow,
                       displays: content.displays
                   ) {
                    return MirageHostCaptureBenchmarkResolvedSource(
                        windowWrapper: SCWindowWrapper(window: resolvedWindow),
                        applicationWrapper: SCApplicationWrapper(application: resolvedApplication),
                        displayWrapper: SCDisplayWrapper(display: resolvedDisplay)
                    )
                }

                if attempt < attempts {
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(500, Int(Double(delayMs) * 1.5))
                }
            } catch {
                if attempt >= attempts {
                    throw MirageHostCaptureBenchmarkError.measurementInvalid(
                        "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
                    )
                }
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(500, Int(Double(delayMs) * 1.5))
            }
        }

        throw MirageHostCaptureBenchmarkError.measurementInvalid(
            "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
        )
    }

    private func resolveDisplayForBenchmarkSourceWindow(
        _ window: SCWindow,
        displays: [SCDisplay]
    ) -> SCDisplay? {
        guard !displays.isEmpty else { return nil }

        let windowFrame = window.frame
        let windowCenter = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        if let containingDisplay = displays.first(where: { $0.frame.contains(windowCenter) }) {
            return containingDisplay
        }

        var bestDisplay: SCDisplay?
        var bestIntersectionArea: CGFloat = 0
        for display in displays {
            let intersection = display.frame.intersection(windowFrame)
            let area = max(0, intersection.width) * max(0, intersection.height)
            if area > bestIntersectionArea {
                bestIntersectionArea = area
                bestDisplay = display
            }
        }

        return bestDisplay ?? displays.first
    }

    private func measureSourcePhase(
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
        let measurementWindow = Locked<MirageHostCaptureBenchmarkMeasurementWindow?>(nil)
        let callbackCount = Locked<UInt64>(0)
        let presentationCounter = Locked(MirageHostCaptureBenchmarkPresentationCounter())
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
            measurementWindow.withLock { $0 = nil }
            cadenceProbe.cancelMeasurement()
        }

        do {
            try await captureEngine.startCapture(
                window: source.windowWrapper.window,
                application: source.applicationWrapper.application,
                display: source.displayWrapper.display,
                onFrame: { frame in
                    let now = CFAbsoluteTimeGetCurrent()
                    let shouldCount = measurementWindow.read { window in
                        window?.contains(now) ?? false
                    }
                    guard shouldCount else { return }
                    callbackCount.withLock { $0 &+= 1 }
                    presentationCounter.withLock { counter in
                        counter.record(frame.presentationTime)
                    }
                }
            )

            _ = await captureEngine.waitForCaptureStartupReadiness(timeout: .seconds(1))

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

            let startupReadiness = await captureEngine.captureStartupReadiness()
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness,
                targetFrameRate: stage.targetFrameRate
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
            cadenceProbe.beginMeasurement()
            let telemetryBaseline = await captureEngine.captureTelemetrySnapshot()

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            measurementWindow.withLock { $0 = nil }
            let telemetryFinal = await captureEngine.captureTelemetrySnapshot()
            let observedDisplayCadenceFPS = cadenceProbe.completeMeasurement(
                durationSeconds: measurementDurationSeconds
            )

            let measurementDuration = max(0.001, measurementEnd - measurementStart)
            let telemetryDelta = captureBenchmarkTelemetryDelta(
                baseline: telemetryBaseline,
                final: telemetryFinal
            )
            let phase = MirageHostCaptureBenchmarkPhaseResult(
                kind: .source,
                callbackFPS: Double(callbackCount.read { $0 }) / measurementDuration,
                presentationFPS: Double(presentationCounter.read { $0.frameCount }) / measurementDuration,
                startupReadiness: MirageHostCaptureBenchmarkStartupReadiness(startupReadiness),
                averageCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
                maximumCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
                averageCopyTimeMs: telemetryDelta.averageCopyTimeMs,
                maximumCopyTimeMs: telemetryDelta.maximumCopyTimeMs,
                cadenceDropCount: telemetryDelta.cadenceDropCount,
                poolDropCount: telemetryDelta.poolDropCount,
                inFlightDropCount: telemetryDelta.inFlightDropCount,
                admissionDropCount: telemetryDelta.admissionDropCount,
                copyFailureCount: telemetryDelta.copyFailureCount
            )

            await captureEngine.stopCapture()

            return MirageHostCaptureBenchmarkPhaseMeasurement(
                phase: phase,
                observedDisplayCadenceFPS: observedDisplayCadenceFPS
            )
        } catch {
            await captureEngine.stopCapture()
            throw error
        }
    }

    private func measureDisplayAndEncodePhase(
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
        let callbackCount = Locked<UInt64>(0)
        let encodedFrameCount = Locked<UInt64>(0)
        let presentationCounter = Locked(MirageHostCaptureBenchmarkPresentationCounter())
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
                display: displayWrapper.display,
                resolution: resolution,
                showsCursor: false,
                onFrame: { frame in
                    let now = CFAbsoluteTimeGetCurrent()
                    let shouldCount = measurementWindow.read { window in
                        window?.contains(now) ?? false
                    }
                    if shouldCount {
                        callbackCount.withLock { $0 &+= 1 }
                        presentationCounter.withLock { counter in
                            counter.record(frame.presentationTime)
                        }
                    }
                    frameContinuation.read { $0 }?.yield(frame)
                }
            )

            _ = await stageCaptureEngine.waitForDisplayStartupReadiness(timeout: .seconds(1))

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

            let startupReadiness = await stageCaptureEngine.displayStartupReadiness()
            if let invalidReason = captureBenchmarkInvalidMeasurementReason(
                startupReadiness: startupReadiness,
                targetFrameRate: stage.targetFrameRate
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
            let telemetryBaseline = await stageCaptureEngine.captureTelemetrySnapshot()

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            measurementWindow.withLock { $0 = nil }
            let telemetryFinal = await stageCaptureEngine.captureTelemetrySnapshot()
            let averageEncodeTimeMs = await stageEncoder.getAverageEncodeTimeMs()

            let measurementDuration = max(0.001, measurementEnd - measurementStart)
            let telemetryDelta = captureBenchmarkTelemetryDelta(
                baseline: telemetryBaseline,
                final: telemetryFinal
            )
            let phase = MirageHostCaptureBenchmarkPhaseResult(
                kind: .display,
                callbackFPS: Double(callbackCount.read { $0 }) / measurementDuration,
                presentationFPS: Double(presentationCounter.read { $0.frameCount }) / measurementDuration,
                startupReadiness: MirageHostCaptureBenchmarkStartupReadiness(startupReadiness),
                averageCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
                maximumCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
                averageCopyTimeMs: telemetryDelta.averageCopyTimeMs,
                maximumCopyTimeMs: telemetryDelta.maximumCopyTimeMs,
                cadenceDropCount: telemetryDelta.cadenceDropCount,
                poolDropCount: telemetryDelta.poolDropCount,
                inFlightDropCount: telemetryDelta.inFlightDropCount,
                admissionDropCount: telemetryDelta.admissionDropCount,
                copyFailureCount: telemetryDelta.copyFailureCount
            )
            let encodeFPS = Double(encodedFrameCount.read { $0 }) / measurementDuration

            await cleanupResources()

            return MirageHostCaptureBenchmarkDisplayMeasurement(
                phase: phase,
                encodeFPS: encodeFPS,
                averageEncodeTimeMs: averageEncodeTimeMs
            )
        } catch {
            await cleanupResources()
            throw error
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

func captureBenchmarkWarnings(
    stage: MirageHostCaptureBenchmarkStage,
    reportedDisplayRefreshRate: Double?,
    observedDisplayCadenceFPS: Double?,
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?
) -> [MirageHostCaptureBenchmarkWarning] {
    var warnings: [MirageHostCaptureBenchmarkWarning] = []
    let targetThreshold = captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)

    if let reportedDisplayRefreshRate,
       Int(reportedDisplayRefreshRate.rounded()) >= stage.refreshRate,
       let observedDisplayCadenceFPS,
       observedDisplayCadenceFPS < captureBenchmarkDisplayCadenceMismatchThreshold(
           targetFrameRate: stage.targetFrameRate
       ) {
        warnings.append(.displayCadenceMismatch)
    }

    if let sourceCapability = sourcePhase?.measuredCapabilityFPS, sourceCapability < targetThreshold {
        warnings.append(.sourceLimited)
    }

    if let displayCapability = displayPhase?.measuredCapabilityFPS, displayCapability < targetThreshold {
        warnings.append(.captureBelowTarget)
    }

    if let encodeFPS, encodeFPS < targetThreshold {
        warnings.append(.encodeBelowTarget)
    }

    return warnings
}

private func deduplicatedBenchmarkWarnings(
    _ warnings: [MirageHostCaptureBenchmarkWarning]
) -> [MirageHostCaptureBenchmarkWarning] {
    var seen = Set<MirageHostCaptureBenchmarkWarning>()
    var ordered: [MirageHostCaptureBenchmarkWarning] = []
    for warning in warnings where seen.insert(warning).inserted {
        ordered.append(warning)
    }
    return ordered
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
