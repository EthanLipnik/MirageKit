//
//  MirageTransportPressure.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

package struct MirageTransportPressureSample: Sendable, Equatable {
    package let queueBytes: Int
    package let queueStressBytes: Int
    package let packetBudgetUtilization: Double?
    package let packetBudgetStressThreshold: Double?
    package let packetPacerAverageSleepMs: Double
    package let packetPacerStressThresholdMs: Double
    package let sendStartDelayAverageMs: Double
    package let sendStartDelayStressThresholdMs: Double
    package let sendCompletionAverageMs: Double
    package let sendCompletionStressThresholdMs: Double
    package let transportDropCount: UInt64

    package init(
        queueBytes: Int = 0,
        queueStressBytes: Int = .max,
        packetBudgetUtilization: Double? = nil,
        packetBudgetStressThreshold: Double? = nil,
        packetPacerAverageSleepMs: Double = 0,
        packetPacerStressThresholdMs: Double = .greatestFiniteMagnitude,
        sendStartDelayAverageMs: Double = 0,
        sendStartDelayStressThresholdMs: Double = .greatestFiniteMagnitude,
        sendCompletionAverageMs: Double = 0,
        sendCompletionStressThresholdMs: Double = .greatestFiniteMagnitude,
        transportDropCount: UInt64 = 0
    ) {
        self.queueBytes = max(0, queueBytes)
        self.queueStressBytes = max(0, queueStressBytes)
        self.packetBudgetUtilization = packetBudgetUtilization.map { max(0, $0) }
        self.packetBudgetStressThreshold = packetBudgetStressThreshold
        self.packetPacerAverageSleepMs = max(0, packetPacerAverageSleepMs)
        self.packetPacerStressThresholdMs = max(0, packetPacerStressThresholdMs)
        self.sendStartDelayAverageMs = max(0, sendStartDelayAverageMs)
        self.sendStartDelayStressThresholdMs = max(0, sendStartDelayStressThresholdMs)
        self.sendCompletionAverageMs = max(0, sendCompletionAverageMs)
        self.sendCompletionStressThresholdMs = max(0, sendCompletionStressThresholdMs)
        self.transportDropCount = transportDropCount
    }
}

package struct MirageTransportPressureAssessment: Sendable, Equatable {
    package let queueStress: Bool
    package let packetBudgetStress: Bool
    package let packetPacerStress: Bool
    package let transportDropStress: Bool
    package let advisoryDelayStress: Bool

    package var primaryStress: Bool {
        queueStress || packetBudgetStress || packetPacerStress || transportDropStress
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
}

package enum MirageTransportPressure {
    package static func assess(sample: MirageTransportPressureSample) -> MirageTransportPressureAssessment {
        let queueStress = sample.queueBytes >= sample.queueStressBytes

        let packetBudgetStress = if let utilization = sample.packetBudgetUtilization,
            let threshold = sample.packetBudgetStressThreshold {
            utilization >= threshold
        } else {
            false
        }

        let packetPacerStress = sample.packetPacerAverageSleepMs >= sample.packetPacerStressThresholdMs

        let transportDropStress = sample.transportDropCount > 0

        let advisoryDelayStress =
            sample.sendStartDelayAverageMs >= sample.sendStartDelayStressThresholdMs ||
            sample.sendCompletionAverageMs >= sample.sendCompletionStressThresholdMs

        return MirageTransportPressureAssessment(
            queueStress: queueStress,
            packetBudgetStress: packetBudgetStress,
            packetPacerStress: packetPacerStress,
            transportDropStress: transportDropStress,
            advisoryDelayStress: advisoryDelayStress
        )
    }
}
