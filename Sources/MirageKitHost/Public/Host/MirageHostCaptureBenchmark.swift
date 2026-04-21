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
    case displayCadenceMismatch
    case sourceGenerationBelowTarget
    case windowIngressBelowTarget
    case windowDeliveryBelowTarget
    case displayIngressBelowTarget
    case displayDeliveryBelowTarget
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
public enum MirageHostCaptureBenchmarkBottleneck: String, Codable, CaseIterable, Hashable, Sendable {
    case sourceGeneration
    case windowIngress
    case windowDelivery
    case displayIngress
    case displayDelivery
    case encode
    case balanced
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkCapturePolicy: Codable, Hashable, Sendable {
    public let effectiveCaptureRate: Int
    public let minimumFrameIntervalRate: Int
    public let usesNativeRefreshMinimumFrameInterval: Bool
    public let sckQueueDepth: Int
    public let usesDisplayRefreshCadence: Bool

    public init(
        effectiveCaptureRate: Int,
        minimumFrameIntervalRate: Int,
        usesNativeRefreshMinimumFrameInterval: Bool,
        sckQueueDepth: Int,
        usesDisplayRefreshCadence: Bool
    ) {
        self.effectiveCaptureRate = effectiveCaptureRate
        self.minimumFrameIntervalRate = minimumFrameIntervalRate
        self.usesNativeRefreshMinimumFrameInterval = usesNativeRefreshMinimumFrameInterval
        self.sckQueueDepth = sckQueueDepth
        self.usesDisplayRefreshCadence = usesDisplayRefreshCadence
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkPhaseResult: Codable, Hashable, Sendable {
    public let kind: MirageHostCaptureBenchmarkPhaseKind
    public let rawIngressFPS: Double?
    public let validSampleFPS: Double?
    public let renderableIngressFPS: Double?
    public let cadenceAdmittedFPS: Double?
    public let deliveryFPS: Double?
    public let startupReadiness: MirageHostCaptureBenchmarkStartupReadiness?
    public let averageCallbackTimeMs: Double?
    public let maximumCallbackTimeMs: Double?
    public let rawCallbackCount: UInt64
    public let validSampleCount: UInt64
    public let renderableSampleCount: UInt64
    public let completeSampleCount: UInt64
    public let idleSampleCount: UInt64
    public let blankSampleCount: UInt64
    public let suspendedSampleCount: UInt64
    public let startedSampleCount: UInt64
    public let stoppedSampleCount: UInt64
    public let cadenceAdmittedCount: UInt64
    public let deliveryCount: UInt64
    public let cadenceDropCount: UInt64
    public let admissionDropCount: UInt64

    public var ingressCapabilityFPS: Double? {
        let measurements = [rawIngressFPS, renderableIngressFPS].compactMap { $0 }
        guard let measuredFloor = measurements.min() else { return nil }
        return measuredFloor
    }

    public var deliveryCapabilityFPS: Double? {
        let measurements = [ingressCapabilityFPS, deliveryFPS].compactMap { $0 }
        guard let measuredFloor = measurements.min() else { return nil }
        return measuredFloor
    }

    public init(
        kind: MirageHostCaptureBenchmarkPhaseKind,
        rawIngressFPS: Double? = nil,
        validSampleFPS: Double? = nil,
        renderableIngressFPS: Double? = nil,
        cadenceAdmittedFPS: Double? = nil,
        deliveryFPS: Double? = nil,
        startupReadiness: MirageHostCaptureBenchmarkStartupReadiness? = nil,
        averageCallbackTimeMs: Double? = nil,
        maximumCallbackTimeMs: Double? = nil,
        rawCallbackCount: UInt64 = 0,
        validSampleCount: UInt64 = 0,
        renderableSampleCount: UInt64 = 0,
        completeSampleCount: UInt64 = 0,
        idleSampleCount: UInt64 = 0,
        blankSampleCount: UInt64 = 0,
        suspendedSampleCount: UInt64 = 0,
        startedSampleCount: UInt64 = 0,
        stoppedSampleCount: UInt64 = 0,
        cadenceAdmittedCount: UInt64 = 0,
        deliveryCount: UInt64 = 0,
        cadenceDropCount: UInt64 = 0,
        admissionDropCount: UInt64 = 0
    ) {
        self.kind = kind
        self.rawIngressFPS = rawIngressFPS
        self.validSampleFPS = validSampleFPS
        self.renderableIngressFPS = renderableIngressFPS
        self.cadenceAdmittedFPS = cadenceAdmittedFPS
        self.deliveryFPS = deliveryFPS
        self.startupReadiness = startupReadiness
        self.averageCallbackTimeMs = averageCallbackTimeMs
        self.maximumCallbackTimeMs = maximumCallbackTimeMs
        self.rawCallbackCount = rawCallbackCount
        self.validSampleCount = validSampleCount
        self.renderableSampleCount = renderableSampleCount
        self.completeSampleCount = completeSampleCount
        self.idleSampleCount = idleSampleCount
        self.blankSampleCount = blankSampleCount
        self.suspendedSampleCount = suspendedSampleCount
        self.startedSampleCount = startedSampleCount
        self.stoppedSampleCount = stoppedSampleCount
        self.cadenceAdmittedCount = cadenceAdmittedCount
        self.deliveryCount = deliveryCount
        self.cadenceDropCount = cadenceDropCount
        self.admissionDropCount = admissionDropCount
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
    public let sourceGenerationFPS: Double?
    public let sourcePhase: MirageHostCaptureBenchmarkPhaseResult?
    public let displayPhase: MirageHostCaptureBenchmarkPhaseResult?
    public let encodeFPS: Double?
    public let sourceCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
    public let displayCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy?
    public let bottleneck: MirageHostCaptureBenchmarkBottleneck?
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
        sourceGenerationFPS: Double? = nil,
        sourcePhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        displayPhase: MirageHostCaptureBenchmarkPhaseResult? = nil,
        encodeFPS: Double? = nil,
        sourceCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy? = nil,
        displayCapturePolicy: MirageHostCaptureBenchmarkCapturePolicy? = nil,
        bottleneck: MirageHostCaptureBenchmarkBottleneck? = nil,
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
        self.sourceGenerationFPS = sourceGenerationFPS
        self.sourcePhase = sourcePhase
        self.displayPhase = displayPhase
        self.encodeFPS = encodeFPS
        self.sourceCapturePolicy = sourceCapturePolicy
        self.displayCapturePolicy = displayCapturePolicy
        self.bottleneck = bottleneck
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

    public var captureCapability: MirageHostCaptureCapability? {
        guard let modeResult = modeResults.first(where: { !$0.lowPowerModeEnabled }) ?? modeResults.first else {
            return nil
        }
        let highestValidStage = modeResult.stageResults.last { $0.meets60FPS }
        let highestSustainedStage = modeResult.stageResults.last { $0.meets120FPS }
        return MirageHostCaptureCapability(
            targetFrameRate: modeResult.summary.targetFrameRate,
            validThresholdFPS: modeResult.summary.validThresholdFPS,
            sustainThresholdFPS: modeResult.summary.sustainThresholdFPS,
            highestValidPixelWidth: highestValidStage?.stage.pixelWidth,
            highestValidPixelHeight: highestValidStage?.stage.pixelHeight,
            highestValidFrameRate: highestValidStage?.validatedCapabilityFPS,
            highestSustainedPixelWidth: highestSustainedStage?.stage.pixelWidth,
            highestSustainedPixelHeight: highestSustainedStage?.stage.pixelHeight,
            highestSustainedFrameRate: highestSustainedStage?.validatedCapabilityFPS,
            measuredAt: measuredAt
        )
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
public final class MirageHostCaptureBenchmarkSourceClock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var displayTickCount: UInt64 = 0
    private var measurementStartTickCount: UInt64 = 0

    public init() {}

    public func noteDisplayTick() {
        stateLock.withLock {
            displayTickCount &+= 1
        }
    }

    public func beginMeasurement() {
        stateLock.withLock {
            measurementStartTickCount = displayTickCount
        }
    }

    public func cancelMeasurement() {
        stateLock.withLock {
            measurementStartTickCount = displayTickCount
        }
    }

    public func completeMeasurement(durationSeconds: Double) -> Double? {
        let clampedDuration = max(0.001, durationSeconds)
        let tickDelta = stateLock.withLock { () -> UInt64 in
            let delta = displayTickCount >= measurementStartTickCount
                ? displayTickCount - measurementStartTickCount
                : 0
            measurementStartTickCount = displayTickCount
            return delta
        }
        guard tickDelta > 0 else { return nil }
        return Double(tickDelta) / clampedDuration
    }
}

@_spi(HostApp)
public struct MirageHostCaptureBenchmarkPreparedSource: Sendable {
    public let windowID: CGWindowID
    public let applicationPID: pid_t
    public let displayID: CGDirectDisplayID
    public let expectedWindowFrame: CGRect?
    public let sourceClock: MirageHostCaptureBenchmarkSourceClock?

    public init(
        windowID: CGWindowID,
        applicationPID: pid_t,
        displayID: CGDirectDisplayID,
        expectedWindowFrame: CGRect? = nil,
        sourceClock: MirageHostCaptureBenchmarkSourceClock? = nil
    ) {
        self.windowID = windowID
        self.applicationPID = applicationPID
        self.displayID = displayID
        self.expectedWindowFrame = expectedWindowFrame
        self.sourceClock = sourceClock
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

func captureBenchmarkSourceFrameMatchesExpected(
    expectedFrame: CGRect,
    actualFrame: CGRect,
    pointTolerance: CGFloat = 2
) -> Bool {
    let expectedWidth = max(1, expectedFrame.width.rounded())
    let expectedHeight = max(1, expectedFrame.height.rounded())
    let actualWidth = max(1, actualFrame.width.rounded())
    let actualHeight = max(1, actualFrame.height.rounded())

    return abs(actualWidth - expectedWidth) <= pointTolerance &&
        abs(actualHeight - expectedHeight) <= pointTolerance
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
    guard let measuredFloor = displayPhase?.deliveryCapabilityFPS else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

func captureBenchmarkValidatedCapabilityFPS(
    sourceGenerationFPS: Double?,
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?,
    targetFrameRate: Int
) -> Double? {
    let measurements = [
        sourceGenerationFPS,
        sourcePhase?.ingressCapabilityFPS,
        sourcePhase?.deliveryCapabilityFPS,
        displayPhase?.ingressCapabilityFPS,
        displayPhase?.deliveryCapabilityFPS,
        encodeFPS,
    ].compactMap { $0 }
    guard let measuredFloor = measurements.min() else { return nil }
    return min(measuredFloor, Double(targetFrameRate))
}

func captureBenchmarkBottleneck(
    stage: MirageHostCaptureBenchmarkStage,
    sourceGenerationFPS: Double?,
    sourcePhase: MirageHostCaptureBenchmarkPhaseResult?,
    displayPhase: MirageHostCaptureBenchmarkPhaseResult?,
    encodeFPS: Double?
) -> MirageHostCaptureBenchmarkBottleneck? {
    let targetThreshold = captureBenchmarkSustainThreshold(targetFrameRate: stage.targetFrameRate)

    if let sourceGenerationFPS, sourceGenerationFPS < targetThreshold {
        return .sourceGeneration
    }
    if let sourceIngressFPS = sourcePhase?.ingressCapabilityFPS, sourceIngressFPS < targetThreshold {
        return .windowIngress
    }
    if let sourceDeliveryFPS = sourcePhase?.deliveryCapabilityFPS, sourceDeliveryFPS < targetThreshold {
        return .windowDelivery
    }
    if let displayIngressFPS = displayPhase?.ingressCapabilityFPS, displayIngressFPS < targetThreshold {
        return .displayIngress
    }
    if let displayDeliveryFPS = displayPhase?.deliveryCapabilityFPS, displayDeliveryFPS < targetThreshold {
        return .displayDelivery
    }
    if let encodeFPS, encodeFPS < targetThreshold {
        return .encode
    }

    let hasMeasurement = sourceGenerationFPS != nil ||
        sourcePhase != nil ||
        displayPhase != nil ||
        encodeFPS != nil
    return hasMeasurement ? .balanced : nil
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
