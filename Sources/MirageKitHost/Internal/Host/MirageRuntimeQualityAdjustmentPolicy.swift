//
//  MirageRuntimeQualityAdjustmentPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//
//  Runtime quality adjustment decisions for low-latency interactive streams.
//

import Foundation
import MirageKit

#if os(macOS)
package struct MirageRuntimeQualityAdjustmentState: Sendable, Equatable {
    package var activeQuality: Float
    package var qualityOverBudgetCount: Int
    package var qualityUnderBudgetCount: Int
}

package enum MirageRuntimeQualityAdjustmentAction: Sendable, Equatable {
    case hold
    case drop(reason: String)
    case raise
}

package struct MirageRuntimeQualityAdjustmentDecision: Sendable, Equatable {
    package let state: MirageRuntimeQualityAdjustmentState
    package let action: MirageRuntimeQualityAdjustmentAction
}

package enum MirageRuntimeQualityAdjustmentPolicy {
    package static func decide(
        state: MirageRuntimeQualityAdjustmentState,
        qualityFloor: Float,
        qualityCeiling: Float,
        encodeOverBudget: Bool,
        packetWithinRaiseBudget: Bool,
        transportAssessment: MirageTransportPressureAssessment,
        allowEncodeDrivenQualityRelief: Bool,
        bitrateConstrained: Bool,
        adaptiveTransportRelief: Bool,
        qualityDropThreshold: Int,
        qualityRaiseThreshold: Int,
        qualityDropStep: Float,
        qualityDropStepHighPressure: Float,
        qualityRaiseStep: Float
    ) -> MirageRuntimeQualityAdjustmentDecision {
        var nextState = state
        let senderBacklogStress = transportAssessment.queueStress || transportAssessment.packetBudgetStress
        let senderBacklogSevere = transportAssessment.queueSevere || transportAssessment.packetBudgetSevere
        let transportDropStress = transportAssessment.transportDropStress && senderBacklogStress
        let transportDropSevere = transportAssessment.transportDropSevere && senderBacklogStress
        let transportStress = senderBacklogStress || transportDropStress
        let transportHighPressure = senderBacklogSevere ||
            transportDropSevere ||
            (transportStress && transportAssessment.advisoryDelaySevere)
        let qualityDropSignal = transportStress || (allowEncodeDrivenQualityRelief && encodeOverBudget)

        if !qualityDropSignal {
            nextState.qualityOverBudgetCount = 0
        } else {
            nextState.qualityUnderBudgetCount = 0
            nextState.qualityOverBudgetCount += 1

            let dropThreshold: Int = if adaptiveTransportRelief && transportHighPressure {
                1
            } else if bitrateConstrained && transportHighPressure {
                1
            } else if bitrateConstrained && transportStress {
                max(1, qualityDropThreshold - 1)
            } else {
                qualityDropThreshold
            }

            let step: Float
            if transportHighPressure {
                let baseStep = bitrateConstrained
                    ? (qualityDropStepHighPressure + 0.03)
                    : qualityDropStepHighPressure
                step = adaptiveTransportRelief ? (baseStep + 0.02) : baseStep
            } else if adaptiveTransportRelief && transportStress {
                step = qualityDropStep + 0.03
            } else if bitrateConstrained && transportStress {
                step = qualityDropStep + 0.01
            } else {
                step = qualityDropStep
            }

            if nextState.qualityOverBudgetCount >= dropThreshold {
                let nextQuality = max(qualityFloor, nextState.activeQuality - step)
                if nextQuality < nextState.activeQuality {
                    nextState.activeQuality = nextQuality
                    nextState.qualityOverBudgetCount = 0
                    var reasonTokens: [String] = []
                    if transportAssessment.queueStress { reasonTokens.append("queue") }
                    if transportAssessment.packetBudgetStress { reasonTokens.append("budget") }
                    if transportAssessment.packetPacerStress { reasonTokens.append("pacer") }
                    if transportDropStress { reasonTokens.append("drops") }
                    if transportAssessment.advisoryDelayStress { reasonTokens.append("delay") }
                    if allowEncodeDrivenQualityRelief, encodeOverBudget {
                        reasonTokens.append("encode")
                    }
                    let reason = reasonTokens.isEmpty ? "unknown" : reasonTokens.joined(separator: "+")
                    return MirageRuntimeQualityAdjustmentDecision(
                        state: nextState,
                        action: .drop(reason: reason)
                    )
                }
            }

            return MirageRuntimeQualityAdjustmentDecision(
                state: nextState,
                action: .hold
            )
        }

        nextState.qualityOverBudgetCount = 0
        guard packetWithinRaiseBudget else {
            nextState.qualityUnderBudgetCount = 0
            return MirageRuntimeQualityAdjustmentDecision(
                state: nextState,
                action: .hold
            )
        }

        nextState.qualityUnderBudgetCount += 1
        if nextState.qualityUnderBudgetCount >= qualityRaiseThreshold {
            let nextQuality = min(qualityCeiling, nextState.activeQuality + qualityRaiseStep)
            if nextQuality > nextState.activeQuality {
                nextState.activeQuality = nextQuality
                nextState.qualityUnderBudgetCount = 0
                return MirageRuntimeQualityAdjustmentDecision(
                    state: nextState,
                    action: .raise
                )
            }
        }

        return MirageRuntimeQualityAdjustmentDecision(
            state: nextState,
            action: .hold
        )
    }
}
#endif
