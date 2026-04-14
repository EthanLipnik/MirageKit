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
            "Low Power On"
        case .lowPowerOff:
            "Low Power Off"
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
    public let captureFPS: Double?
    public let encodeFPS: Double?
    public let effectiveFPS: Double?
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
    public let unsupportedReason: String?
    public let failureDescription: String?

    public var actualPixelDescription: String? {
        guard let actualPixelWidth, let actualPixelHeight else { return nil }
        let actual = "\(actualPixelWidth)x\(actualPixelHeight)"
        return actual != stage.pixelDescription ? actual : nil
    }

    public init(
        stage: MirageHostCaptureBenchmarkStage,
        status: MirageHostCaptureBenchmarkStageStatus,
        actualPixelWidth: Int? = nil,
        actualPixelHeight: Int? = nil,
        captureFPS: Double? = nil,
        encodeFPS: Double? = nil,
        effectiveFPS: Double? = nil,
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
        unsupportedReason: String? = nil,
        failureDescription: String? = nil
    ) {
        self.stage = stage
        self.status = status
        self.actualPixelWidth = actualPixelWidth
        self.actualPixelHeight = actualPixelHeight
        self.captureFPS = captureFPS
        self.encodeFPS = encodeFPS
        self.effectiveFPS = effectiveFPS
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
    public static let currentVersion = 1

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

enum MirageHostCaptureBenchmarkDisplayValidationResult: Equatable {
    case exact
    case accepted(actualWidth: Int, actualHeight: Int)
    case unsupported(String)
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
        return .unsupported(
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
    case .completed, .unsupported, .failed:
        true
    case .cancelled:
        false
    }
}

func captureBenchmarkSummary(
    stageResults: [MirageHostCaptureBenchmarkStageResult]
) -> MirageHostCaptureBenchmarkSummary {
    let targetFrameRate = stageResults.last?.stage.targetFrameRate ??
        MirageHostCaptureBenchmarkStage.allStages.last?.targetFrameRate ?? 120
    let threshold = Double(targetFrameRate) * 0.95
    let highestStage = stageResults.last(where: { result in
        result.status == .completed &&
            (result.effectiveFPS ?? 0) >= threshold
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
