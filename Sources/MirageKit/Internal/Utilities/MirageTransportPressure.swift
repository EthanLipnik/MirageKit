//
//  MirageTransportPressure.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//
//  Shared transport-pressure classification used by host and client controllers.
//

import Foundation

package struct MirageTransportPressureSample: Sendable, Equatable {
    package let queueBytes: Int
    package let queueStressBytes: Int
    package let queueSevereBytes: Int
    package let packetBudgetUtilization: Double?
    package let packetBudgetStressThreshold: Double?
    package let packetBudgetSevereThreshold: Double?
    package let packetPacerAverageSleepMs: Double
    package let packetPacerStressThresholdMs: Double
    package let packetPacerSevereThresholdMs: Double
    package let sendStartDelayAverageMs: Double
    package let sendStartDelayStressThresholdMs: Double
    package let sendStartDelaySevereThresholdMs: Double
    package let sendCompletionAverageMs: Double
    package let sendCompletionStressThresholdMs: Double
    package let sendCompletionSevereThresholdMs: Double
    package let transportDropCount: UInt64
    package let transportDropSevereCount: UInt64
    package let encodedFPS: Double?
    package let deliveredFPS: Double?
    package let deliveryStressRatio: Double?
    package let deliverySevereRatio: Double?

    package init(
        queueBytes: Int = 0,
        queueStressBytes: Int = .max,
        queueSevereBytes: Int = .max,
        packetBudgetUtilization: Double? = nil,
        packetBudgetStressThreshold: Double? = nil,
        packetBudgetSevereThreshold: Double? = nil,
        packetPacerAverageSleepMs: Double = 0,
        packetPacerStressThresholdMs: Double = .greatestFiniteMagnitude,
        packetPacerSevereThresholdMs: Double = .greatestFiniteMagnitude,
        sendStartDelayAverageMs: Double = 0,
        sendStartDelayStressThresholdMs: Double = .greatestFiniteMagnitude,
        sendStartDelaySevereThresholdMs: Double = .greatestFiniteMagnitude,
        sendCompletionAverageMs: Double = 0,
        sendCompletionStressThresholdMs: Double = .greatestFiniteMagnitude,
        sendCompletionSevereThresholdMs: Double = .greatestFiniteMagnitude,
        transportDropCount: UInt64 = 0,
        transportDropSevereCount: UInt64 = .max,
        encodedFPS: Double? = nil,
        deliveredFPS: Double? = nil,
        deliveryStressRatio: Double? = nil,
        deliverySevereRatio: Double? = nil
    ) {
        self.queueBytes = max(0, queueBytes)
        self.queueStressBytes = max(0, queueStressBytes)
        self.queueSevereBytes = max(0, queueSevereBytes)
        self.packetBudgetUtilization = packetBudgetUtilization.map { max(0, $0) }
        self.packetBudgetStressThreshold = packetBudgetStressThreshold
        self.packetBudgetSevereThreshold = packetBudgetSevereThreshold
        self.packetPacerAverageSleepMs = max(0, packetPacerAverageSleepMs)
        self.packetPacerStressThresholdMs = max(0, packetPacerStressThresholdMs)
        self.packetPacerSevereThresholdMs = max(0, packetPacerSevereThresholdMs)
        self.sendStartDelayAverageMs = max(0, sendStartDelayAverageMs)
        self.sendStartDelayStressThresholdMs = max(0, sendStartDelayStressThresholdMs)
        self.sendStartDelaySevereThresholdMs = max(0, sendStartDelaySevereThresholdMs)
        self.sendCompletionAverageMs = max(0, sendCompletionAverageMs)
        self.sendCompletionStressThresholdMs = max(0, sendCompletionStressThresholdMs)
        self.sendCompletionSevereThresholdMs = max(0, sendCompletionSevereThresholdMs)
        self.transportDropCount = transportDropCount
        self.transportDropSevereCount = transportDropSevereCount
        self.encodedFPS = encodedFPS.map { max(0, $0) }
        self.deliveredFPS = deliveredFPS.map { max(0, $0) }
        self.deliveryStressRatio = deliveryStressRatio
        self.deliverySevereRatio = deliverySevereRatio
    }
}

package struct MirageTransportPressureAssessment: Sendable, Equatable {
    package let queueStress: Bool
    package let queueSevere: Bool
    package let packetBudgetStress: Bool
    package let packetBudgetSevere: Bool
    package let packetPacerStress: Bool
    package let packetPacerSevere: Bool
    package let transportDropStress: Bool
    package let transportDropSevere: Bool
    package let deliveryStress: Bool
    package let deliverySevere: Bool
    package let advisoryDelayStress: Bool
    package let advisoryDelaySevere: Bool

    package var primaryStress: Bool {
        queueStress || packetBudgetStress || packetPacerStress || transportDropStress
    }

    package var primarySevere: Bool {
        queueSevere || packetBudgetSevere || packetPacerSevere || transportDropSevere
    }

    package var isStress: Bool {
        primaryStress
    }

    package var isSevere: Bool {
        primarySevere || (primaryStress && advisoryDelaySevere)
    }

    package var isDelayOnlyBurst: Bool {
        !primaryStress && advisoryDelayStress
    }

    package var isPacerOnlyStress: Bool {
        packetPacerStress &&
            !queueStress &&
            !packetBudgetStress &&
            !transportDropStress
    }

    package var pipelineCadenceStress: Bool {
        deliveryStress
    }

    package var pipelineCadenceSevere: Bool {
        deliverySevere
    }

    package var reasonTokens: [String] {
        var tokens: [String] = []
        if queueStress { tokens.append("queue") }
        if packetBudgetStress { tokens.append("budget") }
        if packetPacerStress { tokens.append("pacer") }
        if transportDropStress { tokens.append("drops") }
        if advisoryDelayStress {
            tokens.append(primaryStress ? "delay" : "delayOnly")
        }
        return tokens
    }

    package var pipelineCadenceReasonTokens: [String] {
        deliveryStress ? ["delivery"] : []
    }
}

package enum MirageTransportPressure {
    package static func assess(sample: MirageTransportPressureSample) -> MirageTransportPressureAssessment {
        let queueStress = sample.queueBytes >= sample.queueStressBytes
        let queueSevere = sample.queueBytes >= sample.queueSevereBytes

        let packetBudgetStress = if let utilization = sample.packetBudgetUtilization,
            let threshold = sample.packetBudgetStressThreshold {
            utilization >= threshold
        } else {
            false
        }
        let packetBudgetSevere = if let utilization = sample.packetBudgetUtilization,
            let threshold = sample.packetBudgetSevereThreshold {
            utilization >= threshold
        } else {
            false
        }

        let packetPacerStress = sample.packetPacerAverageSleepMs >= sample.packetPacerStressThresholdMs
        let packetPacerSevere = sample.packetPacerAverageSleepMs >= sample.packetPacerSevereThresholdMs

        let transportDropStress = sample.transportDropCount > 0
        let transportDropSevere = sample.transportDropCount >= sample.transportDropSevereCount

        let deliveryStress = if let encodedFPS = sample.encodedFPS,
            let deliveredFPS = sample.deliveredFPS,
            let ratio = sample.deliveryStressRatio,
            encodedFPS > 0 {
            deliveredFPS < encodedFPS * ratio
        } else {
            false
        }
        let deliverySevere = if let encodedFPS = sample.encodedFPS,
            let deliveredFPS = sample.deliveredFPS,
            let ratio = sample.deliverySevereRatio,
            encodedFPS > 0 {
            deliveredFPS < encodedFPS * ratio
        } else {
            false
        }

        let advisoryDelayStress =
            sample.sendStartDelayAverageMs >= sample.sendStartDelayStressThresholdMs ||
            sample.sendCompletionAverageMs >= sample.sendCompletionStressThresholdMs
        let advisoryDelaySevere =
            sample.sendStartDelayAverageMs >= sample.sendStartDelaySevereThresholdMs ||
            sample.sendCompletionAverageMs >= sample.sendCompletionSevereThresholdMs

        return MirageTransportPressureAssessment(
            queueStress: queueStress,
            queueSevere: queueSevere,
            packetBudgetStress: packetBudgetStress,
            packetBudgetSevere: packetBudgetSevere,
            packetPacerStress: packetPacerStress,
            packetPacerSevere: packetPacerSevere,
            transportDropStress: transportDropStress,
            transportDropSevere: transportDropSevere,
            deliveryStress: deliveryStress,
            deliverySevere: deliverySevere,
            advisoryDelayStress: advisoryDelayStress,
            advisoryDelaySevere: advisoryDelaySevere
        )
    }
}
