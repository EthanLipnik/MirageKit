//
//  MirageClientVideoIngressMetricsSnapshot.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

package struct MirageClientVideoIngressMetricsSnapshot: Sendable, Equatable {
    package let loomStreamDeliveryPPS: Double
    package let loomStreamDeliveryIntervalMaxMs: Double
    package let rawPacketIngressPPS: Double
    package let incomingBatchRate: Double
    package let incomingBatchIntervalP95Ms: Double
    package let incomingBatchIntervalP99Ms: Double
    package let incomingBatchIntervalMaxMs: Double
    package let incomingBatchMaxSize: Int
    package let incomingBatchAverageSize: Double
    package let queuedBatchCount: Int
    package let queuedPacketCount: Int
    package let queueAgeMaxMs: Double
    package let stalePacketDropCount: UInt64
    package let overloadPacketDropCount: UInt64
    package let protectedOverloadPacketDropCount: UInt64
    package let processedPacketCount: UInt64
    package let processorWakeDelayMaxMs: Double

    package init(
        loomStreamDeliveryPPS: Double,
        loomStreamDeliveryIntervalMaxMs: Double,
        rawPacketIngressPPS: Double,
        incomingBatchRate: Double,
        incomingBatchIntervalP95Ms: Double,
        incomingBatchIntervalP99Ms: Double,
        incomingBatchIntervalMaxMs: Double,
        incomingBatchMaxSize: Int,
        incomingBatchAverageSize: Double,
        queuedBatchCount: Int,
        queuedPacketCount: Int,
        queueAgeMaxMs: Double,
        stalePacketDropCount: UInt64,
        overloadPacketDropCount: UInt64,
        protectedOverloadPacketDropCount: UInt64,
        processedPacketCount: UInt64,
        processorWakeDelayMaxMs: Double
    ) {
        self.loomStreamDeliveryPPS = loomStreamDeliveryPPS
        self.loomStreamDeliveryIntervalMaxMs = loomStreamDeliveryIntervalMaxMs
        self.rawPacketIngressPPS = rawPacketIngressPPS
        self.incomingBatchRate = incomingBatchRate
        self.incomingBatchIntervalP95Ms = incomingBatchIntervalP95Ms
        self.incomingBatchIntervalP99Ms = incomingBatchIntervalP99Ms
        self.incomingBatchIntervalMaxMs = incomingBatchIntervalMaxMs
        self.incomingBatchMaxSize = incomingBatchMaxSize
        self.incomingBatchAverageSize = incomingBatchAverageSize
        self.queuedBatchCount = queuedBatchCount
        self.queuedPacketCount = queuedPacketCount
        self.queueAgeMaxMs = queueAgeMaxMs
        self.stalePacketDropCount = stalePacketDropCount
        self.overloadPacketDropCount = overloadPacketDropCount
        self.protectedOverloadPacketDropCount = protectedOverloadPacketDropCount
        self.processedPacketCount = processedPacketCount
        self.processorWakeDelayMaxMs = processorWakeDelayMaxMs
    }
}
