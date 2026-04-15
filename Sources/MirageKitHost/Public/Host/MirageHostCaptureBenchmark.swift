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
public enum MirageHostCaptureBenchmarkPhaseKind: String, Codable, Hashable, Sendable {
    case source
    case display
}

@_spi(HostApp)
public enum MirageHostCaptureBenchmarkWarning: String, Codable, CaseIterable, Sendable {
    case quantizedResolution
    case sourceLimited
    case displayCadenceMismatch
    case captureBelowTarget
    case encodeBelowTarget
}

@_spi(HostApp)
public enum MirageHostCaptureBenchmarkStartupReadiness: String, Codable, Hashable, Sendable {
    case usableFrameSeen
    case idleFrameSeen
    case blankOrSuspendedOnly
    case noScreenSamples
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkPhaseResult: Codable, Hashable, Sendable {
    public let kind: MirageHostCaptureBenchmarkPhaseKind
    public let callbackFPS: Double?
    public let presentationFPS: Double?
    public let startupReadiness: MirageHostCaptureBenchmarkStartupReadiness?
    public let averageCallbackTimeMs: Double?
    public let maximumCallbackTimeMs: Double?
    public let averageCopyTimeMs: Double?
    public let maximumCopyTimeMs: Double?
    public let cadenceDropCount: UInt64
    public let poolDropCount: UInt64
    public let inFlightDropCount: UInt64
    public let admissionDropCount: UInt64
    public let copyFailureCount: UInt64

    public var measuredCapabilityFPS: Double? {
        let measurements = [callbackFPS, presentationFPS].compactMap { $0 }
        guard let measuredFloor = measurements.min() else { return nil }
        return measuredFloor
    }

    public init(
        kind: MirageHostCaptureBenchmarkPhaseKind,
        callbackFPS: Double? = nil,
        presentationFPS: Double? = nil,
        startupReadiness: MirageHostCaptureBenchmarkStartupReadiness? = nil,
        averageCallbackTimeMs: Double? = nil,
        maximumCallbackTimeMs: Double? = nil,
        averageCopyTimeMs: Double? = nil,
        maximumCopyTimeMs: Double? = nil,
        cadenceDropCount: UInt64 = 0,
        poolDropCount: UInt64 = 0,
        inFlightDropCount: UInt64 = 0,
        admissionDropCount: UInt64 = 0,
        copyFailureCount: UInt64 = 0
    ) {
        self.kind = kind
        self.callbackFPS = callbackFPS
        self.presentationFPS = presentationFPS
        self.startupReadiness = startupReadiness
        self.averageCallbackTimeMs = averageCallbackTimeMs
        self.maximumCallbackTimeMs = maximumCallbackTimeMs
        self.averageCopyTimeMs = averageCopyTimeMs
        self.maximumCopyTimeMs = maximumCopyTimeMs
        self.cadenceDropCount = cadenceDropCount
        self.poolDropCount = poolDropCount
        self.inFlightDropCount = inFlightDropCount
        self.admissionDropCount = admissionDropCount
        self.copyFailureCount = copyFailureCount
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkSummary: Codable, Hashable, Sendable {
    public let targetFrameRate: Int
    public let validThresholdFPS: Double
    public let sustainThresholdFPS: Double
    public let highestValidStageID: String?
    public let highestValidStageTitle: String?
    public let highestValidResolution: String?
    public let highest120FPSStageID: String?
    public let highest120FPSStageTitle: String?
    public let highest120FPSResolution: String?

    public init(
        targetFrameRate: Int,
        validThresholdFPS: Double,
        sustainThresholdFPS: Double,
        highestValidStageID: String?,
        highestValidStageTitle: String?,
        highestValidResolution: String?,
        highest120FPSStageID: String?,
        highest120FPSStageTitle: String?,
        highest120FPSResolution: String?
    ) {
        self.targetFrameRate = targetFrameRate
        self.validThresholdFPS = validThresholdFPS
        self.sustainThresholdFPS = sustainThresholdFPS
        self.highestValidStageID = highestValidStageID
        self.highestValidStageTitle = highestValidStageTitle
        self.highestValidResolution = highestValidResolution
        self.highest120FPSStageID = highest120FPSStageID
        self.highest120FPSStageTitle = highest120FPSStageTitle
        self.highest120FPSResolution = highest120FPSResolution
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkStageResult: Codable, Hashable, Sendable {
    public let stage: MirageHostCaptureBenchmarkStage
    public let status: MirageHostCaptureBenchmarkStageStatus
    public let actualPixelWidth: Int?
    public let actualPixelHeight: Int?
    public let reportedDisplayRefreshRate: Double?
    public let observedDisplayCadenceFPS: Double?
    public let sourcePhase: MirageHostCaptureBenchmarkPhaseResult?
    public let displayPhase: MirageHostCaptureBenchmarkPhaseResult?
    public let encodeFPS: Double?
    public let displayCaptureCapabilityFPS: Double?
    public let validatedCapabilityFPS: Double?
    public let averageEncodeTimeMs: Double?
    public let warnings: [MirageHostCaptureBenchmarkWarning]
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
            guard let reportedDisplayRefreshRate else { return nil }
            let roundedRefreshRate = Int(reportedDisplayRefreshRate.rounded())
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
        (validatedCapabilityFPS ?? 0) >= captureBenchmarkValidThresholdFPS()
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
        reportedDisplayRefreshRate: Double? = nil,
        observedDisplayCadenceFPS: Double? = nil,
        sourcePhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        displayPhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        encodeFPS: Double? = nil,
        displayCaptureCapabilityFPS: Double? = nil,
        validatedCapabilityFPS: Double? = nil,
        averageEncodeTimeMs: Double? = nil,
        warnings: [MirageHostCaptureBenchmarkWarning] = [],
        invalidMeasurementReason: String? = nil,
        unsupportedReason: String? = nil,
        failureDescription: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.actualPixelWidth = actualPixelWidth
        self.actualPixelHeight = actualPixelHeight
        self.reportedDisplayRefreshRate = reportedDisplayRefreshRate
        self.observedDisplayCadenceFPS = observedDisplayCadenceFPS
        self.sourcePhase = sourcePhase
        self.displayPhase = displayPhase
        self.encodeFPS = encodeFPS
        self.displayCaptureCapabilityFPS = displayCaptureCapabilityFPS
        self.validatedCapabilityFPS = validatedCapabilityFPS
        self.averageEncodeTimeMs = averageEncodeTimeMs
        self.warnings = warnings
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
    public static let currentVersion = 3

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

    private let spaceID: CGSSpaceID

    init(
        stage: MirageHostCaptureBenchmarkStage,
        modeSelection: MirageHostCaptureBenchmarkModeSelection,
        displayID: CGDirectDisplayID,
        displayBounds: CGRect,
        pixelSize: CGSize,
        spaceID: CGSSpaceID
    ) {
        self.stage = stage
        self.modeSelection = modeSelection
        self.displayID = displayID
        self.displayBounds = displayBounds
        self.pixelSize = pixelSize
        self.spaceID = spaceID
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

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkPreparedSource: Hashable, Sendable {
    public let windowID: CGWindowID
    public let applicationPID: pid_t
    public let displayID: CGDirectDisplayID

    public init(
        windowID: CGWindowID,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID
    ) {
        self.windowID = windowID
        self.applicationPID = applicationPID
        self.displayID = displayID
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

func captureBenchmarkValidThresholdFPS() -> Double {
    60
}

func captureBenchmarkSustainThreshold(targetFrameRate: Int) -> Double {
    Double(targetFrameRate) * 0.95
}

func captureBenchmarkDisplayCadenceMismatchThreshold(targetFrameRate: Int) -> Double {
    max(captureBenchmarkValidThresholdFPS(), Double(targetFrameRate) * 0.75)
}

func captureBenchmarkInvalidMeasurementReason(
    displayValidationResult: MirageHostCaptureBenchmarkDisplayValidationResult? = nil,
    displayCadenceProbeFailed: Bool = false,
    startupReadiness: DisplayCaptureStartupReadiness? = nil,
    targetFrameRate _: Int
) -> String? {
    if case let .invalid(reason)? = displayValidationResult {
        return reason
    }

    if displayCadenceProbeFailed {
        return "Display cadence probe failed to attach to the benchmark display."
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

    return nil
}

func captureBenchmarkDisplayCapabilityFPS(
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    targetFrameRate: Int
) -> Double? {
    guard let measuredFloor = displayPhase?.measuredCapabilityFPS else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

func captureBenchmarkValidatedCapabilityFPS(
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?,
    targetFrameRate: Int
) -> Double? {
    let measurements = [
        sourcePhase?.measuredCapabilityFPS,
        displayPhase?.measuredCapabilityFPS,
        encodeFPS,
    ].compactMap { $0 }
    guard let measuredFloor = measurements.min() else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

func captureBenchmarkSummary(
    stageResults: [MirageHostCaptureBenchmarkStageResult]
) -> MirageHostCaptureBenchmarkSummary {
    let targetFrameRate = stageResults.last?.stage.targetFrameRate ??
        MirageHostCaptureBenchmarkStage.allStages.last?.targetFrameRate ?? 120
    let validThreshold = captureBenchmarkValidThresholdFPS()
    let threshold = captureBenchmarkSustainThreshold(targetFrameRate: targetFrameRate)
    let highestValidStage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.validatedCapabilityFPS ?? 0) >= validThreshold
    })
    let highest120Stage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.validatedCapabilityFPS ?? 0) >= threshold
    })

    return MirageHostCaptureBenchmarkSummary(
        targetFrameRate: targetFrameRate,
        validThresholdFPS: validThreshold,
        sustainThresholdFPS: threshold,
        highestValidStageID: highestValidStage?.stage.id,
        highestValidStageTitle: highestValidStage?.stage.title,
        highestValidResolution: highestValidStage?.stage.pixelDescription,
        highest120FPSStageID: highest120Stage?.stage.id,
        highest120FPSStageTitle: highest120Stage?.stage.title,
        highest120FPSResolution: highest120Stage?.stage.pixelDescription
    )
}

extension MirageHostCaptureBenchmarkStartupReadiness {
    init(_ readiness: DisplayCaptureStartupReadiness) {
        switch readiness {
        case .usableFrameSeen:
            self = .usableFrameSeen
        case .idleFrameSeen:
            self = .idleFrameSeen
        case .blankOrSuspendedOnly:
            self = .blankOrSuspendedOnly
        case .noScreenSamples:
            self = .noScreenSamples
        }
    }
}
#endif
