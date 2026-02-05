//
//  MirageQualityProbeResult.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/3/26.
//
//  Probe results for automatic quality validation.
//

import Foundation

public struct MirageQualityProbeResult: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let pixelFormat: MiragePixelFormat
    public let hostEncodeMs: Double?
    public let clientDecodeMs: Double?
    public let hostObservedBitrateBps: Int?
    public let transportThroughputBps: Int?
    public let transportLossPercent: Double?

    public init(
        width: Int,
        height: Int,
        frameRate: Int,
        pixelFormat: MiragePixelFormat,
        hostEncodeMs: Double?,
        clientDecodeMs: Double?,
        hostObservedBitrateBps: Int?,
        transportThroughputBps: Int? = nil,
        transportLossPercent: Double? = nil
    ) {
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
        self.hostEncodeMs = hostEncodeMs
        self.clientDecodeMs = clientDecodeMs
        self.hostObservedBitrateBps = hostObservedBitrateBps
        self.transportThroughputBps = transportThroughputBps
        self.transportLossPercent = transportLossPercent
    }
}
