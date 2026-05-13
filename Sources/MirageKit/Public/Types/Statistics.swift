//
//  Statistics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/2/26.
//

import Foundation

/// Runtime statistics for an active media stream.
public struct MirageStreamStatistics: Sendable {
    /// Current frame rate.
    public let currentFrameRate: Double

    /// Total frames encoded on the host or decoded on the client.
    public let processedFrames: UInt64

    /// Total frames dropped.
    public let droppedFrames: UInt64

    /// Average end-to-end latency in milliseconds.
    public let averageLatencyMs: Double

    /// Current bandwidth utilization from `0` to `1`.
    public let bandwidthUtilization: Double

    /// Round-trip time in milliseconds.
    public let rttMs: Double

    /// Packet loss ratio from `0` to `1`.
    public let packetLoss: Double

    /// Current quality level label.
    public let qualityLevel: String

    /// Stream uptime in seconds.
    public let uptime: TimeInterval

    /// Creates a stream statistics snapshot.
    /// - Parameters:
    ///   - currentFrameRate: Current frame rate in frames per second.
    ///   - processedFrames: Frames successfully encoded or decoded.
    ///   - droppedFrames: Frames dropped before presentation.
    ///   - averageLatencyMs: Average end-to-end latency in milliseconds.
    ///   - bandwidthUtilization: Bandwidth utilization ratio from `0` to `1`.
    ///   - rttMs: Round-trip time in milliseconds.
    ///   - packetLoss: Packet loss ratio from `0` to `1`.
    ///   - qualityLevel: Human-readable quality label.
    ///   - uptime: Stream uptime in seconds.
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

    /// Ratio of dropped frames to total observed frames.
    public var dropRate: Double {
        let observedFrames = Double(processedFrames) + Double(droppedFrames)
        guard observedFrames > 0 else { return 0 }
        return Double(droppedFrames) / observedFrames
    }

    /// Average latency formatted for compact status UI.
    public var formattedLatency: String {
        let value = averageLatencyMs.formatted(.number.precision(.fractionLength(1)))
        return "\(value) ms"
    }
}
