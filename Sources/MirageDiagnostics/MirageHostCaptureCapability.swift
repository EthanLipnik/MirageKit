//
//  MirageHostCaptureCapability.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Host capture throughput capability inferred from benchmark or quality-test measurements.
public struct MirageHostCaptureCapability: Codable, Equatable, Sendable {
    /// Frame rate the capability measurement targeted.
    public let targetFrameRate: Int
    /// Minimum FPS considered valid for a resolution candidate.
    public let validThresholdFPS: Double
    /// Minimum FPS considered sustained for a resolution candidate.
    public let sustainThresholdFPS: Double
    /// Width of the highest resolution that met the valid threshold.
    public let highestValidPixelWidth: Int?
    /// Height of the highest resolution that met the valid threshold.
    public let highestValidPixelHeight: Int?
    /// Measured frame rate for the highest valid resolution.
    public let highestValidFrameRate: Double?
    /// Width of the highest resolution that met the sustained threshold.
    public let highestSustainedPixelWidth: Int?
    /// Height of the highest resolution that met the sustained threshold.
    public let highestSustainedPixelHeight: Int?
    /// Measured frame rate for the highest sustained resolution.
    public let highestSustainedFrameRate: Double?
    /// When the capability measurement was produced.
    public let measuredAt: Date?

    /// Creates a capture capability summary.
    public init(
        targetFrameRate: Int,
        validThresholdFPS: Double,
        sustainThresholdFPS: Double,
        highestValidPixelWidth: Int?,
        highestValidPixelHeight: Int?,
        highestValidFrameRate: Double?,
        highestSustainedPixelWidth: Int?,
        highestSustainedPixelHeight: Int?,
        highestSustainedFrameRate: Double?,
        measuredAt: Date? = nil
    ) {
        self.targetFrameRate = targetFrameRate
        self.validThresholdFPS = validThresholdFPS
        self.sustainThresholdFPS = sustainThresholdFPS
        self.highestValidPixelWidth = highestValidPixelWidth
        self.highestValidPixelHeight = highestValidPixelHeight
        self.highestValidFrameRate = highestValidFrameRate
        self.highestSustainedPixelWidth = highestSustainedPixelWidth
        self.highestSustainedPixelHeight = highestSustainedPixelHeight
        self.highestSustainedFrameRate = highestSustainedFrameRate
        self.measuredAt = measuredAt
    }

    /// Pixel count for the highest resolution that met the valid threshold.
    public var highestValidPixelCount: Int? {
        guard let highestValidPixelWidth, let highestValidPixelHeight else { return nil }
        return Self.pixelCount(width: highestValidPixelWidth, height: highestValidPixelHeight)
    }

    /// Pixel count for the highest resolution that met the sustained threshold.
    public var highestSustainedPixelCount: Int? {
        guard let highestSustainedPixelWidth, let highestSustainedPixelHeight else { return nil }
        return Self.pixelCount(width: highestSustainedPixelWidth, height: highestSustainedPixelHeight)
    }

    private static func pixelCount(width: Int, height: Int) -> Int? {
        let product = width.multipliedReportingOverflow(by: height)
        guard !product.overflow else { return nil }
        return product.partialValue
    }
}
