//
//  MirageRuntimeQualityAdjustmentPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//
//  Runtime quality adjustment decisions for low-latency interactive streams.
//

import Foundation

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
        allowsRaise: Bool,
        allowEncodeDrivenQualityRelief: Bool,
        qualityDropThreshold: Int,
        qualityRaiseThreshold: Int,
        qualityDropStep: Float,
        qualityRaiseStep: Float
    ) -> MirageRuntimeQualityAdjustmentDecision {
        var nextState = state
        let qualityDropSignal = allowEncodeDrivenQualityRelief && encodeOverBudget

        if !qualityDropSignal {
            nextState.qualityOverBudgetCount = 0
        } else {
            nextState.qualityUnderBudgetCount = 0
            nextState.qualityOverBudgetCount += 1

            if nextState.qualityOverBudgetCount >= qualityDropThreshold {
                let nextQuality = max(qualityFloor, nextState.activeQuality - qualityDropStep)
                if nextQuality < nextState.activeQuality {
                    nextState.activeQuality = nextQuality
                    nextState.qualityOverBudgetCount = 0
                    return MirageRuntimeQualityAdjustmentDecision(
                        state: nextState,
                        action: .drop(reason: "encode")
                    )
                }
            }

            return MirageRuntimeQualityAdjustmentDecision(
                state: nextState,
                action: .hold
            )
        }

        nextState.qualityOverBudgetCount = 0
        guard allowsRaise else {
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
