//
//  MirageHostCaptureCapability.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/21/26.
//
//  Host capture capability summary shared with quality-test results.
//

import Foundation

public struct MirageHostCaptureCapability: Codable, Equatable, Sendable {
    public let targetFrameRate: Int
    public let validThresholdFPS: Double
    public let sustainThresholdFPS: Double
    public let highestValidPixelWidth: Int?
    public let highestValidPixelHeight: Int?
    public let highestValidFrameRate: Double?
    public let highestSustainedPixelWidth: Int?
    public let highestSustainedPixelHeight: Int?
    public let highestSustainedFrameRate: Double?
    public let measuredAt: Date?

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

    public var highestValidPixelCount: Int? {
        guard let highestValidPixelWidth, let highestValidPixelHeight else { return nil }
        return highestValidPixelWidth * highestValidPixelHeight
    }

    public var highestSustainedPixelCount: Int? {
        guard let highestSustainedPixelWidth, let highestSustainedPixelHeight else { return nil }
        return highestSustainedPixelWidth * highestSustainedPixelHeight
    }
}
