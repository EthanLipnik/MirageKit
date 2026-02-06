//
//  Statistics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Statistics for an active stream
public struct MirageStreamStatistics: Sendable {
    /// Current frame rate
    public let currentFrameRate: Double

    /// Total frames encoded (host) or decoded (client)
    public let processedFrames: UInt64

    /// Total frames dropped
    public let droppedFrames: UInt64

    /// Average end-to-end latency in milliseconds
    public let averageLatencyMs: Double

    /// Current bandwidth utilization (0.0 - 1.0)
    public let bandwidthUtilization: Double

    /// Round-trip time in milliseconds
    public let rttMs: Double

    /// Packet loss ratio (0.0 - 1.0)
    public let packetLoss: Double

    /// Current quality level name
    public let qualityLevel: String

    /// Stream uptime in seconds
    public let uptime: TimeInterval

    public init(
        currentFrameRate: Double = 0,
        processedFrames: UInt64 = 0,
        droppedFrames: UInt64 = 0,
        averageLatencyMs: Double = 0,
        bandwidthUtilization: Double = 0,
        rttMs: Double = 0,
        packetLoss: Double = 0,
        qualityLevel: String = "Unknown",
        uptime: TimeInterval = 0
    ) {
        self.currentFrameRate = currentFrameRate
        self.processedFrames = processedFrames
        self.droppedFrames = droppedFrames
        self.averageLatencyMs = averageLatencyMs
        self.bandwidthUtilization = bandwidthUtilization
        self.rttMs = rttMs
        self.packetLoss = packetLoss
        self.qualityLevel = qualityLevel
        self.uptime = uptime
    }

    /// Frame drop percentage
    public var dropRate: Double {
        guard processedFrames > 0 else { return 0 }
        return Double(droppedFrames) / Double(processedFrames + droppedFrames)
    }

    /// Formatted latency string
    public var formattedLatency: String {
        let value = averageLatencyMs.formatted(.number.precision(.fractionLength(1)))
        return "\(value) ms"
    }
}

/// Network quality assessment
public struct MirageNetworkQuality: Sendable {
    /// Overall quality score (0.0 - 1.0)
    public let overallScore: Double

    /// Connection stability score
    public let stabilityScore: Double

    /// Available bandwidth score
    public let capacityScore: Double

    /// Reliability score (inverse of packet loss)
    public let reliabilityScore: Double

    public init(
        overallScore: Double,
        stabilityScore: Double,
        capacityScore: Double,
        reliabilityScore: Double
    ) {
        self.overallScore = overallScore
        self.stabilityScore = stabilityScore
        self.capacityScore = capacityScore
        self.reliabilityScore = reliabilityScore
    }

    /// Quality rating for display
    public var rating: QualityRating {
        switch overallScore {
        case 0.8...: .excellent
        case 0.6 ..< 0.8: .good
        case 0.4 ..< 0.6: .fair
        case 0.2 ..< 0.4: .poor
        default: .critical
        }
    }

    public enum QualityRating: String, Sendable {
        case excellent
        case good
        case fair
        case poor
        case critical

        public var displayName: String { rawValue.capitalized }

        public var systemImage: String {
            switch self {
            case .excellent: "wifi"
            case .good: "wifi"
            case .fair: "wifi.exclamationmark"
            case .poor: "wifi.slash"
            case .critical: "wifi.slash"
            }
        }
    }
}
