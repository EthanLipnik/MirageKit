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

@MainActor
extension MirageHostService {
    /// Runs the host capture benchmark for the requested stages and mode selections.
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
        guard connectedClients.isEmpty, activeStreams.isEmpty, desktopStreamID == nil else {
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

                if result.status == .cancelled {
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

    /// Runs one configured benchmark stage and returns its measured result.
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

            guard let displayBounds = await SharedVirtualDisplayManager.shared.displayBounds else {
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

}

#endif
