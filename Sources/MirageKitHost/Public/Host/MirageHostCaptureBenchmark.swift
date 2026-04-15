//
//  MirageHostCaptureBenchmark.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)
import AppKit

@_spi(HostApp)
public enum MirageHostCaptureBenchmarkModeSelection: String, Codable, CaseIterable, Sendable, Identifiable {
    case lowPowerOn
    case lowPowerOff

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .lowPowerOn:
            "Encoder Low Power On"
        case .lowPowerOff:
            "Encoder Low Power Off"
        }
    }

    public var lowPowerEnabled: Bool {
        self == .lowPowerOn
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkStage: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let refreshRate: Int
    public let targetFrameRate: Int

    public init(
        id: String,
        title: String,
        pixelWidth: Int,
        pixelHeight: Int,
        refreshRate: Int = 120,
        targetFrameRate: Int = 120
    ) {
        self.id = id
        self.title = title
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.targetFrameRate = targetFrameRate
    }

    public var pixelSize: CGSize {
        CGSize(width: pixelWidth, height: pixelHeight)
    }

    public var pixelDescription: String {
        "\(pixelWidth)x\(pixelHeight)"
    }

    public static let benchmark1080p = MirageHostCaptureBenchmarkStage(
        id: "1080p",
        title: "1080p",
        pixelWidth: 1920,
        pixelHeight: 1080
    )

    public static let benchmark2K = MirageHostCaptureBenchmarkStage(
        id: "2k",
        title: "2K",
        pixelWidth: 2560,
        pixelHeight: 1440
    )

    public static let benchmark4K = MirageHostCaptureBenchmarkStage(
        id: "4k",
        title: "4K",
        pixelWidth: 3840,
        pixelHeight: 2160
    )

    public static let benchmark5K = MirageHostCaptureBenchmarkStage(
        id: "5k",
        title: "5K",
        pixelWidth: 5120,
        pixelHeight: 2880
    )

    public static let benchmark6K = MirageHostCaptureBenchmarkStage(
        id: "6k",
        title: "6K",
        pixelWidth: 6016,
        pixelHeight: 3384
    )

    public static let allStages: [MirageHostCaptureBenchmarkStage] = [
        .benchmark1080p,
        .benchmark2K,
        .benchmark4K,
        .benchmark5K,
        .benchmark6K,
    ]
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkConfiguration: Codable, Hashable, Sendable {
    public let modeSelections: [MirageHostCaptureBenchmarkModeSelection]
    public let stages: [MirageHostCaptureBenchmarkStage]
    public let warmupDurationSeconds: Double
    public let measurementDurationSeconds: Double

    public init(
        modeSelections: [MirageHostCaptureBenchmarkModeSelection],
        stages: [MirageHostCaptureBenchmarkStage] = MirageHostCaptureBenchmarkStage.allStages,
        warmupDurationSeconds: Double = 1,
        measurementDurationSeconds: Double = 5
    ) {
        self.modeSelections = Self.normalizedModeSelections(modeSelections)
        self.stages = stages
        self.warmupDurationSeconds = warmupDurationSeconds
        self.measurementDurationSeconds = measurementDurationSeconds
    }

    public static var standard: MirageHostCaptureBenchmarkConfiguration {
        MirageHostCaptureBenchmarkConfiguration(modeSelections: [.lowPowerOff])
    }

    public var cacheKey: String {
        let modesText = modeSelections.map(\.rawValue).joined(separator: "-")
        let stagesText = stages
            .map { "\($0.id)-\($0.pixelWidth)x\($0.pixelHeight)" }
            .joined(separator: "_")
        let warmupMs = Int((warmupDurationSeconds * 1000).rounded())
        let measurementMs = Int((measurementDurationSeconds * 1000).rounded())
        return "v\(MirageHostCaptureBenchmarkReport.currentVersion)-modes-\(modesText)-stages-\(stagesText)-warmup-\(warmupMs)-measure-\(measurementMs)"
    }

    public static func normalizedModeSelections(
        _ selections: [MirageHostCaptureBenchmarkModeSelection]
    ) -> [MirageHostCaptureBenchmarkModeSelection] {
        Array(Set(selections)).sorted { $0.rawValue < $1.rawValue }
    }
}

@_spi(HostApp)
public enum MirageHostCaptureBenchmarkStageStatus: String, Codable, Sendable {
    case completed
    case invalid
    case unsupported
    case failed
    case cancelled
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkSummary: Codable, Hashable, Sendable {
    public let targetFrameRate: Int
    public let sustainThresholdFPS: Double
    public let highestSustainedStageID: String?
    public let highestSustainedStageTitle: String?
    public let highestSustainedResolution: String?

    public init(
        targetFrameRate: Int,
        sustainThresholdFPS: Double,
        highestSustainedStageID: String?,
        highestSustainedStageTitle: String?,
        highestSustainedResolution: String?
    ) {
        self.targetFrameRate = targetFrameRate
        self.sustainThresholdFPS = sustainThresholdFPS
        self.highestSustainedStageID = highestSustainedStageID
        self.highestSustainedStageTitle = highestSustainedStageTitle
        self.highestSustainedResolution = highestSustainedResolution
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkStageResult: Codable, Hashable, Sendable {
    public let stage: MirageHostCaptureBenchmarkStage
    public let status: MirageHostCaptureBenchmarkStageStatus
    public let actualPixelWidth: Int?
    public let actualPixelHeight: Int?
    public let observedDisplayRefreshRate: Double?
    public let observedSourceFPS: Double?
    public let captureFPS: Double?
    public let observedCapturePresentationFPS: Double?
    public let encodeFPS: Double?
    public let effectiveFPS: Double?
    public let validatedCapabilityFPS: Double?
    public let averageEncodeTimeMs: Double?
    public let averageCaptureCallbackTimeMs: Double?
    public let maximumCaptureCallbackTimeMs: Double?
    public let averageCaptureCopyTimeMs: Double?
    public let maximumCaptureCopyTimeMs: Double?
    public let cadenceDropCount: UInt64
    public let poolDropCount: UInt64
    public let inFlightDropCount: UInt64
    public let admissionDropCount: UInt64
    public let copyFailureCount: UInt64
    public let invalidMeasurementReason: String?
    public let unsupportedReason: String?
    public let failureDescription: String?

    public var actualPixelDescription: String? {
        guard let actualPixelWidth, let actualPixelHeight else { return nil }
        let actual = "\(actualPixelWidth)x\(actualPixelHeight)"
        return actual != stage.pixelDescription ? actual : nil
    }

    public var actualDisplayModeDescription: String? {
        let refreshDescription: String? = {
            guard let observedDisplayRefreshRate else { return nil }
            let roundedRefreshRate = Int(observedDisplayRefreshRate.rounded())
            guard roundedRefreshRate != stage.refreshRate else { return nil }
            return "\(roundedRefreshRate)Hz"
        }()

        switch (actualPixelDescription, refreshDescription) {
        case let (.some(pixelDescription), .some(refreshRateDescription)):
            return "\(pixelDescription) @ \(refreshRateDescription)"
        case let (.some(pixelDescription), nil):
            return pixelDescription
        case let (nil, .some(refreshRateDescription)):
            return refreshRateDescription
        case (nil, nil):
            return nil
        }
    }

    public var meets60FPS: Bool {
        (validatedCapabilityFPS ?? 0) >= 60
    }

    public var meets120FPS: Bool {
        guard let validatedCapabilityFPS else { return false }
        return validatedCapabilityFPS >= captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)
    }

    public init(
        stage: MirageHostCaptureBenchmarkStage,
        status: MirageHostCaptureBenchmarkStageStatus,
        actualPixelWidth: Int? = nil,
        actualPixelHeight: Int? = nil,
        observedDisplayRefreshRate: Double? = nil,
        observedSourceFPS: Double? = nil,
        captureFPS: Double? = nil,
        observedCapturePresentationFPS: Double? = nil,
        encodeFPS: Double? = nil,
        effectiveFPS: Double? = nil,
        validatedCapabilityFPS: Double? = nil,
        averageEncodeTimeMs: Double? = nil,
        averageCaptureCallbackTimeMs: Double? = nil,
        maximumCaptureCallbackTimeMs: Double? = nil,
        averageCaptureCopyTimeMs: Double? = nil,
        maximumCaptureCopyTimeMs: Double? = nil,
        cadenceDropCount: UInt64 = 0,
        poolDropCount: UInt64 = 0,
        inFlightDropCount: UInt64 = 0,
        admissionDropCount: UInt64 = 0,
        copyFailureCount: UInt64 = 0,
        invalidMeasurementReason: String? = nil,
        unsupportedReason: String? = nil,
        failureDescription: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.actualPixelWidth = actualPixelWidth
        self.actualPixelHeight = actualPixelHeight
        self.observedDisplayRefreshRate = observedDisplayRefreshRate
        self.observedSourceFPS = observedSourceFPS
        self.captureFPS = captureFPS
        self.observedCapturePresentationFPS = observedCapturePresentationFPS
        self.encodeFPS = encodeFPS
        self.effectiveFPS = effectiveFPS
        self.validatedCapabilityFPS = validatedCapabilityFPS
        self.averageEncodeTimeMs = averageEncodeTimeMs
        self.averageCaptureCallbackTimeMs = averageCaptureCallbackTimeMs
        self.maximumCaptureCallbackTimeMs = maximumCaptureCallbackTimeMs
        self.averageCaptureCopyTimeMs = averageCaptureCopyTimeMs
        self.maximumCaptureCopyTimeMs = maximumCaptureCopyTimeMs
        self.cadenceDropCount = cadenceDropCount
        self.poolDropCount = poolDropCount
        self.inFlightDropCount = inFlightDropCount
        self.admissionDropCount = admissionDropCount
        self.copyFailureCount = copyFailureCount
        self.invalidMeasurementReason = invalidMeasurementReason
        self.unsupportedReason = unsupportedReason
        self.failureDescription = failureDescription
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkModeResult: Codable, Hashable, Sendable {
    public let modeSelection: MirageHostCaptureBenchmarkModeSelection
    public let lowPowerModeEnabled: Bool
    public let stageResults: [MirageHostCaptureBenchmarkStageResult]
    public let summary: MirageHostCaptureBenchmarkSummary

    public init(
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        lowPowerModeEnabled: Bool,
        stageResults: [MirageHostCaptureBenchmarkStageResult]
    ) {
        self.modeSelection = modeSelection
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.stageResults = stageResults
        summary = captureBenchmarkSummary(stageResults: stageResults)
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkReport: Codable, Hashable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    public let machineID: UUID
    public let hostName: String
    public let hardwareModelIdentifier: String?
    public let hardwareMachineFamily: String?
    public let appVersion: String
    public let buildVersion: String
    public let operatingSystemVersion: String
    public let configuration: MirageHostCaptureBenchmarkConfiguration
    public let measuredAt: Date
    public let modeResults: [MirageHostCaptureBenchmarkModeResult]
    public let didCancel: Bool

    public init(
        version: Int = Self.currentVersion,
        machineID: UUID,
        hostName: String,
        hardwareModelIdentifier: String?,
        hardwareMachineFamily: String?,
        appVersion: String,
        buildVersion: String,
        operatingSystemVersion: String,
        configuration: MirageHostCaptureBenchmarkConfiguration,
        measuredAt: Date,
        modeResults: [MirageHostCaptureBenchmarkModeResult],
        didCancel: Bool
    ) {
        self.version = version
        self.machineID = machineID
        self.hostName = hostName
        self.hardwareModelIdentifier = hardwareModelIdentifier
        self.hardwareMachineFamily = hardwareMachineFamily
        self.appVersion = appVersion
        self.buildVersion = buildVersion
        self.operatingSystemVersion = operatingSystemVersion
        self.configuration = configuration
        self.measuredAt = measuredAt
        self.modeResults = modeResults
        self.didCancel = didCancel
    }

    public func isReusable(
        machineID: UUID,
        appVersion: String,
        operatingSystemVersion: String,
        configuration: MirageHostCaptureBenchmarkConfiguration
    ) -> Bool {
        version == Self.currentVersion &&
            !didCancel &&
            self.machineID == machineID &&
            self.appVersion == appVersion &&
            self.operatingSystemVersion == operatingSystemVersion &&
            self.configuration == configuration
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkProgress: Sendable, Equatable {
    public enum Phase: String, Sendable {
        case preparing
        case warmingUp
        case measuring
        case completed
        case cancelled
    }

    public let phase: Phase
    public let modeSelection: MirageHostCaptureBenchmarkModeSelection
    public let stage: MirageHostCaptureBenchmarkStage
    public let completedStageCount: Int
    public let totalStageCount: Int
    public let message: String

    public init(
        phase: Phase,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        stage: MirageHostCaptureBenchmarkStage,
        completedStageCount: Int,
        totalStageCount: Int,
        message: String
    ) {
        self.phase = phase
        self.modeSelection = modeSelection
        self.stage = stage
        self.completedStageCount = completedStageCount
        self.totalStageCount = totalStageCount
        self.message = message
    }
}

@_spi(HostApp)
@MainActor
public final class MirageHostCaptureBenchmarkWindowConfiguration {
    public let stage: MirageHostCaptureBenchmarkStage
    public let modeSelection: MirageHostCaptureBenchmarkModeSelection
    public let displayID: CGDirectDisplayID
    public let displayBounds: CGRect
    public let pixelSize: CGSize
    public let sourceRuntime: MirageHostCaptureBenchmarkSourceRuntime

    private let spaceID: CGSSpaceID

    init(
        stage: MirageHostCaptureBenchmarkStage,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        pixelSize: CGSize,
        spaceID: CGSSpaceID,
        sourceRuntime: MirageHostCaptureBenchmarkSourceRuntime
    ) {
        self.stage = stage
        self.modeSelection = modeSelection
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.pixelSize = pixelSize
        self.spaceID = spaceID
        self.sourceRuntime = sourceRuntime
    }

    public func install(window: NSWindow) {
        let targetFrame = resolvedTargetFrame(for: displayID, fallback: displayBounds)
        window.setFrame(targetFrame, display: true)
        window.orderFront(nil)
        let windowID = CGWindowID(window.windowNumber)
        guard windowID != 0 else {
            window.displayIfNeeded()
            return
        }
        _ = CGSWindowSpaceBridge.setCurrentSpaceForDisplay(displayID, spaceID: spaceID)
        CGSWindowSpaceBridge.moveWindowToSpace(windowID, spaceID: spaceID)
        window.setFrame(targetFrame, display: true)
        _ = CGSWindowSpaceBridge.bringWindowToFront(windowID)
        window.displayIfNeeded()
    }

    private func resolvedTargetFrame(
        for displayID: CGDirectDisplayID,
        fallback: CGRect
    ) -> CGRect {
        if let screen = NSScreen.screens.first(where: {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDirectDisplayID(number.uint32Value) == displayID
        }) {
            return screen.frame
        }
        return fallback
    }
}

enum MirageHostCaptureBenchmarkDisplayValidationResult: Equatable {
    case exact
    case accepted(actualWidth: Int, actualHeight: Int)
    case invalid(String)
}

func captureBenchmarkDisplayValidationResult(
    requestedStage: MirageHostCaptureBenchmarkStage,
    actualResolution: CGSize,
    actualRefreshRate: Double
) -> MirageHostCaptureBenchmarkDisplayValidationResult {
    let actualWidth = Int(actualResolution.width.rounded())
    let actualHeight = Int(actualResolution.height.rounded())
    let actualRefresh = Int(actualRefreshRate.rounded())

    guard actualRefresh == requestedStage.refreshRate else {
        return .invalid(
            "Requested \(requestedStage.refreshRate)Hz but acquired \(actualRefresh)Hz."
        )
    }

    if actualWidth == requestedStage.pixelWidth, actualHeight == requestedStage.pixelHeight {
        return .exact
    }

    return .accepted(actualWidth: actualWidth, actualHeight: actualHeight)
}

func captureBenchmarkShouldContinue(
    after status: MirageHostCaptureBenchmarkStageStatus
) -> Bool {
    switch status {
    case .completed, .invalid, .unsupported, .failed:
        true
    case .cancelled:
        false
    }
}

func captureBenchmarkSustainThreshold(targetFrameRate: Int) -> Double {
    Double(targetFrameRate) * 0.95
}

func captureBenchmarkSourceMeasurementThreshold(targetFrameRate: Int) -> Double {
    captureBenchmarkSustainThreshold(targetFrameRate: targetFrameRate)
}

func captureBenchmarkInvalidMeasurementReason(
    displayValidationResult: MirageHostCaptureBenchmarkDisplayValidationResult? = nil,
    startupReadiness: DisplayCaptureStartupReadiness? = nil,
    sourceFPS: Double? = nil,
    validateSourceCadence: Bool = true,
    targetFrameRate: Int
) -> String? {
    if case let .invalid(reason)? = displayValidationResult {
        return reason
    }

    if let startupReadiness {
        switch startupReadiness {
        case .blankOrSuspendedOnly:
            return "Capture startup only produced blank or suspended frames."
        case .noScreenSamples:
            return "Capture startup did not produce screen samples."
        case .usableFrameSeen, .idleFrameSeen:
            break
        }
    }

    guard validateSourceCadence else { return nil }
    let threshold = captureBenchmarkSourceMeasurementThreshold(targetFrameRate: targetFrameRate)
    guard let sourceFPS else {
        return "Source cadence was unavailable during measurement."
    }
    guard sourceFPS >= threshold else {
        let observedText = sourceFPS.formatted(.number.precision(.fractionLength(1)))
        let thresholdText = threshold.formatted(.number.precision(.fractionLength(1)))
        return "Source cadence reached \(observedText) fps; need at least \(thresholdText) fps for a valid \(targetFrameRate) Hz workload."
    }
    return nil
}

func captureBenchmarkValidatedCapabilityFPS(
    sourceFPS: Double?,
    capturePresentationFPS: Double?,
    encodeFPS: Double?,
    targetFrameRate: Int
) -> Double? {
    let measurements = [sourceFPS, capturePresentationFPS, encodeFPS].compactMap { $0 }
    guard let measuredFloor = measurements.min() else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

func captureBenchmarkSummary(
    stageResults: [MirageHostCaptureBenchmarkStageResult]
) -> MirageHostCaptureBenchmarkSummary {
    let targetFrameRate = stageResults.last?.stage.targetFrameRate ??
        MirageHostCaptureBenchmarkStage.allStages.last?.targetFrameRate ?? 120
    let threshold = captureBenchmarkSustainThreshold(targetFrameRate: targetFrameRate)
    let highestStage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.validatedCapabilityFPS ?? 0) >= threshold
    })

    return MirageHostCaptureBenchmarkSummary(
        targetFrameRate: targetFrameRate,
        sustainThresholdFPS: threshold,
        highestSustainedStageID: highestStage?.stage.id,
        highestSustainedStageTitle: highestStage?.stage.title,
        highestSustainedResolution: highestStage?.stage.pixelDescription
    )
}
#endif
