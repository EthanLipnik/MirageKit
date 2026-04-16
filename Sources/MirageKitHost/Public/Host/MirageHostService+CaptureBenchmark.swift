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
    let rawCallbackCount: UInt64
    let validSampleCount: UInt64
    let renderableSampleCount: UInt64
    let completeSampleCount: UInt64
    let idleSampleCount: UInt64
    let blankSampleCount: UInt64
    let suspendedSampleCount: UInt64
    let startedSampleCount: UInt64
    let stoppedSampleCount: UInt64
    let cadenceAdmittedCount: UInt64
    let deliveryCount: UInt64
    let averageCallbackTimeMs: Double?
    let maximumCallbackTimeMs: Double?
    let cadenceDropCount: UInt64
    let admissionDropCount: UInt64
}

private struct MirageHostCaptureBenchmarkResolvedSource {
    let windowWrapper: SCWindowWrapper
    let applicationWrapper: SCApplicationWrapper
    let displayWrapper: SCDisplayWrapper
    let sourceClock: MirageHostCaptureBenchmarkSourceClock?
}

private struct MirageHostCaptureBenchmarkPhaseMeasurement {
    let phase: MirageHostCaptureBenchmarkPhaseResult
    let observedDisplayCadenceFPS: Double?
    let sourceGenerationFPS: Double?
    let capturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
}

private struct MirageHostCaptureBenchmarkDisplayMeasurement {
    let phase: MirageHostCaptureBenchmarkPhaseResult
    let encodeFPS: Double?
    let averageEncodeTimeMs: Double?
    let capturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
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
            let sourceGenerationFPS = sourceMeasurement.sourceGenerationFPS
            let bottleneck = captureBenchmarkBottleneck(
                stage: stage,
                sourceGenerationFPS: sourceGenerationFPS,
                sourcePhase: sourcePhase,
                displayPhase: displayPhase,
                encodeFPS: encodeFPS
            )

            stageWarnings = deduplicatedBenchmarkWarnings(
                stageWarnings +
                    captureBenchmarkWarnings(
                        stage: stage,
                        reportedDisplayRefreshRate: displaySnapshot.refreshRate,
                        observedDisplayCadenceFPS: observedDisplayCadenceFPS,
                        bottleneck: bottleneck
                    )
            )

            let displayCaptureCapabilityFPS = captureBenchmarkDisplayCapabilityFPS(
                displayPhase: displayPhase,
                targetFrameRate: stage.targetFrameRate
            )
            let validatedCapabilityFPS = captureBenchmarkValidatedCapabilityFPS(
                sourceGenerationFPS: sourceGenerationFPS,
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
                sourceGenerationFPS: sourceGenerationFPS,
                sourcePhase: sourcePhase,
                displayPhase: displayPhase,
                encodeFPS: encodeFPS,
                sourceCapturePolicy: sourceMeasurement.capturePolicy,
                displayCapturePolicy: displayMeasurement.capturePolicy,
                bottleneck: bottleneck,
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
        var settledObservationCount = 0
        var lastFailureReason = "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."

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
                   let targetDisplay = content.displays.first(where: {
                       $0.displayID == preparedSource.displayID
                   }) ?? content.displays.first(where: {
                       $0.displayID == fallbackDisplayID
                   }) {
                    let resolvedDisplay = resolveDisplayForBenchmarkSourceWindow(
                        resolvedWindow,
                        displays: content.displays
                    ) ?? targetDisplay
                    if let geometryMismatchReason = benchmarkSourceGeometryMismatchReason(
                        preparedSource: preparedSource,
                        resolvedWindow: resolvedWindow,
                        resolvedDisplayID: resolvedDisplay.displayID
                    ) {
                        settledObservationCount = 0
                        lastFailureReason = geometryMismatchReason
                    } else {
                        settledObservationCount += 1
                        if settledObservationCount >= 2 || attempts == 1 {
                            return MirageHostCaptureBenchmarkResolvedSource(
                                windowWrapper: SCWindowWrapper(window: resolvedWindow),
                                applicationWrapper: SCApplicationWrapper(application: resolvedApplication),
                                displayWrapper: SCDisplayWrapper(display: resolvedDisplay),
                                sourceClock: preparedSource.sourceClock
                            )
                        }
                        lastFailureReason =
                            "Benchmark source window geometry is still settling at \(benchmarkFrameDescription(resolvedWindow.frame))."
                    }
                } else {
                    settledObservationCount = 0
                    lastFailureReason =
                        "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
                }

                if attempt < attempts {
                    try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                    delayMs = min(500, Int(Double(delayMs) * 1.5))
                }
            } catch {
                settledObservationCount = 0
                lastFailureReason =
                    "Benchmark source window \(preparedSource.windowID) did not surface in ScreenCaptureKit."
                if attempt >= attempts {
                    throw MirageHostCaptureBenchmarkError.measurementInvalid(
                        lastFailureReason
                    )
                }
                try? await Task.sleep(for: .milliseconds(Int64(delayMs)))
                delayMs = min(500, Int(Double(delayMs) * 1.5))
            }
        }

        throw MirageHostCaptureBenchmarkError.measurementInvalid(
            lastFailureReason
        )
    }

    private func benchmarkSourceGeometryMismatchReason(
        preparedSource: MirageHostCaptureBenchmarkPreparedSource,
        resolvedWindow: SCWindow,
        resolvedDisplayID: CGDirectDisplayID
    ) -> String? {
        if resolvedDisplayID != preparedSource.displayID {
            return "Benchmark source window surfaced on display \(resolvedDisplayID) instead of \(preparedSource.displayID)."
        }

        if let expectedWindowFrame = preparedSource.expectedWindowFrame,
           !captureBenchmarkSourceFrameMatchesExpected(
               expectedFrame: expectedWindowFrame,
               actualFrame: resolvedWindow.frame
           ) {
            return "Benchmark source window geometry did not settle. Expected \(benchmarkFrameDescription(expectedWindowFrame)), observed \(benchmarkFrameDescription(resolvedWindow.frame))."
        }

        return nil
    }

    private func benchmarkFrameDescription(_ frame: CGRect) -> String {
        let originX = Int(frame.origin.x.rounded())
        let originY = Int(frame.origin.y.rounded())
        let width = Int(frame.width.rounded())
        let height = Int(frame.height.rounded())
        return "\(width)x\(height)@(\(originX),\(originY))"
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
            let capturePolicy = await captureEngine.capturePolicySnapshot().benchmarkPolicy

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
            source.sourceClock?.beginMeasurement()
            cadenceProbe.beginMeasurement()
            let telemetryBaseline = await captureEngine.captureTelemetrySnapshot()

            try await sleepForBenchmark(durationSeconds: measurementDurationSeconds)

            let telemetryFinal = await captureEngine.captureTelemetrySnapshot()
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
            let phase = MirageHostCaptureBenchmarkPhaseResult(
                kind: .source,
                rawIngressFPS: Double(telemetryDelta.rawCallbackCount) / measurementDuration,
                validSampleFPS: Double(telemetryDelta.validSampleCount) / measurementDuration,
                renderableIngressFPS: Double(telemetryDelta.renderableSampleCount) / measurementDuration,
                cadenceAdmittedFPS: Double(telemetryDelta.cadenceAdmittedCount) / measurementDuration,
                deliveryFPS: Double(telemetryDelta.deliveryCount) / measurementDuration,
                startupReadiness: MirageHostCaptureBenchmarkStartupReadiness(startupReadiness),
                averageCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
                maximumCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
                rawCallbackCount: telemetryDelta.rawCallbackCount,
                validSampleCount: telemetryDelta.validSampleCount,
                renderableSampleCount: telemetryDelta.renderableSampleCount,
                completeSampleCount: telemetryDelta.completeSampleCount,
                idleSampleCount: telemetryDelta.idleSampleCount,
                blankSampleCount: telemetryDelta.blankSampleCount,
                suspendedSampleCount: telemetryDelta.suspendedSampleCount,
                startedSampleCount: telemetryDelta.startedSampleCount,
                stoppedSampleCount: telemetryDelta.stoppedSampleCount,
                cadenceAdmittedCount: telemetryDelta.cadenceAdmittedCount,
                deliveryCount: telemetryDelta.deliveryCount,
                cadenceDropCount: telemetryDelta.cadenceDropCount,
                admissionDropCount: telemetryDelta.admissionDropCount
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
                    frameContinuation.read { $0 }?.yield(frame)
                }
            )

            _ = await stageCaptureEngine.waitForDisplayStartupReadiness(timeout: .seconds(1))
            let capturePolicy = await stageCaptureEngine.capturePolicySnapshot().benchmarkPolicy

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
                rawIngressFPS: Double(telemetryDelta.rawCallbackCount) / measurementDuration,
                validSampleFPS: Double(telemetryDelta.validSampleCount) / measurementDuration,
                renderableIngressFPS: Double(telemetryDelta.renderableSampleCount) / measurementDuration,
                cadenceAdmittedFPS: Double(telemetryDelta.cadenceAdmittedCount) / measurementDuration,
                deliveryFPS: Double(telemetryDelta.deliveryCount) / measurementDuration,
                startupReadiness: MirageHostCaptureBenchmarkStartupReadiness(startupReadiness),
                averageCallbackTimeMs: telemetryDelta.averageCallbackTimeMs,
                maximumCallbackTimeMs: telemetryDelta.maximumCallbackTimeMs,
                rawCallbackCount: telemetryDelta.rawCallbackCount,
                validSampleCount: telemetryDelta.validSampleCount,
                renderableSampleCount: telemetryDelta.renderableSampleCount,
                completeSampleCount: telemetryDelta.completeSampleCount,
                idleSampleCount: telemetryDelta.idleSampleCount,
                blankSampleCount: telemetryDelta.blankSampleCount,
                suspendedSampleCount: telemetryDelta.suspendedSampleCount,
                startedSampleCount: telemetryDelta.startedSampleCount,
                stoppedSampleCount: telemetryDelta.stoppedSampleCount,
                cadenceAdmittedCount: telemetryDelta.cadenceAdmittedCount,
                deliveryCount: telemetryDelta.deliveryCount,
                cadenceDropCount: telemetryDelta.cadenceDropCount,
                admissionDropCount: telemetryDelta.admissionDropCount
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
    bottleneck: MirageHostCaptureBenchmarkBottleneck?
) -> [MirageHostCaptureBenchmarkWarning] {
    var warnings: [MirageHostCaptureBenchmarkWarning] = []

    if let reportedDisplayRefreshRate,
       Int(reportedDisplayRefreshRate.rounded()) >= stage.refreshRate,
       let observedDisplayCadenceFPS,
       observedDisplayCadenceFPS < captureBenchmarkDisplayCadenceMismatchThreshold(
           targetFrameRate: stage.targetFrameRate
       ) {
        warnings.append(.displayCadenceMismatch)
    }

    switch bottleneck {
    case .sourceGeneration:
        warnings.append(.sourceGenerationBelowTarget)
    case .windowIngress:
        warnings.append(.windowIngressBelowTarget)
    case .windowDelivery:
        warnings.append(.windowDeliveryBelowTarget)
    case .displayIngress:
        warnings.append(.displayIngressBelowTarget)
    case .displayDelivery:
        warnings.append(.displayDeliveryBelowTarget)
    case .encode:
        warnings.append(.encodeBelowTarget)
    case .balanced, .none:
        break
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
    let rawCallbackCount = subtractCounter(
        final?.rawScreenCallbackCount ?? 0,
        baseline?.rawScreenCallbackCount ?? 0
    )
    let validSampleCount = subtractCounter(
        final?.validScreenSampleCount ?? 0,
        baseline?.validScreenSampleCount ?? 0
    )
    let renderableSampleCount = subtractCounter(
        final?.renderableScreenSampleCount ?? 0,
        baseline?.renderableScreenSampleCount ?? 0
    )
    let completeSampleCount = subtractCounter(
        final?.completeFrameCount ?? 0,
        baseline?.completeFrameCount ?? 0
    )
    let idleSampleCount = subtractCounter(
        final?.idleFrameCount ?? 0,
        baseline?.idleFrameCount ?? 0
    )
    let blankSampleCount = subtractCounter(
        final?.blankFrameCount ?? 0,
        baseline?.blankFrameCount ?? 0
    )
    let suspendedSampleCount = subtractCounter(
        final?.suspendedFrameCount ?? 0,
        baseline?.suspendedFrameCount ?? 0
    )
    let startedSampleCount = subtractCounter(
        final?.startedFrameCount ?? 0,
        baseline?.startedFrameCount ?? 0
    )
    let stoppedSampleCount = subtractCounter(
        final?.stoppedFrameCount ?? 0,
        baseline?.stoppedFrameCount ?? 0
    )
    let cadenceAdmittedCount = subtractCounter(
        final?.cadenceAdmittedFrameCount ?? 0,
        baseline?.cadenceAdmittedFrameCount ?? 0
    )
    let deliveryCount = subtractCounter(
        final?.deliveredFrameCount ?? 0,
        baseline?.deliveredFrameCount ?? 0
    )

    return MirageHostCaptureBenchmarkTelemetryDelta(
        rawCallbackCount: rawCallbackCount,
        validSampleCount: validSampleCount,
        renderableSampleCount: renderableSampleCount,
        completeSampleCount: completeSampleCount,
        idleSampleCount: idleSampleCount,
        blankSampleCount: blankSampleCount,
        suspendedSampleCount: suspendedSampleCount,
        startedSampleCount: startedSampleCount,
        stoppedSampleCount: stoppedSampleCount,
        cadenceAdmittedCount: cadenceAdmittedCount,
        deliveryCount: deliveryCount,
        averageCallbackTimeMs: callbackSampleDelta > 0
            ? callbackTotalDelta / Double(callbackSampleDelta)
            : nil,
        maximumCallbackTimeMs: final?.callbackDurationMaxMs,
        cadenceDropCount: subtractCounter(
            final?.cadenceDropCount ?? 0,
            baseline?.cadenceDropCount ?? 0
        ),
        admissionDropCount: subtractCounter(
            final?.admissionDropCount ?? 0,
            baseline?.admissionDropCount ?? 0
        )
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
