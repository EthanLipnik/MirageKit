//
//  StreamContextMosaicTileQualityGovernor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/7/26.
//

import Foundation

#if os(macOS)

struct StreamContextMosaicTileQualityGovernor: Sendable {
    private struct State: Sendable {
        var quality: Float
        var quietRefreshStreak: Int
    }

    private var activePlanEpoch: UInt32?
    private var statesByMediaUnitIndex: [UInt16: State] = [:]

    mutating func reset() {
        activePlanEpoch = nil
        statesByMediaUnitIndex.removeAll(keepingCapacity: false)
    }

    mutating func quality(
        for workItem: StreamContextMosaicMediaUnitWorkItem,
        activeQuality: Float,
        configuredCeiling: Float,
        compressionCeiling: Float
    ) -> Float {
        resetForPlanEpochIfNeeded(workItem.plan.epoch)

        let floor = max(0.02, min(activeQuality, compressionCeiling))
        let ceiling = max(floor, min(configuredCeiling, compressionCeiling))
        var state = statesByMediaUnitIndex[workItem.mediaUnitIndex] ?? State(
            quality: floor,
            quietRefreshStreak: 0
        )

        if workItem.isQualityRefresh || !workItem.isDirty {
            state.quietRefreshStreak += 1
            let step: Float = state.quietRefreshStreak < 4 ? 0.06 : 0.10
            state.quality = min(ceiling, max(floor, state.quality + step))
        } else {
            state.quietRefreshStreak = 0
            state.quality = floor
        }

        statesByMediaUnitIndex[workItem.mediaUnitIndex] = state
        return state.quality
    }

    private mutating func resetForPlanEpochIfNeeded(_ planEpoch: UInt32) {
        guard activePlanEpoch != planEpoch else { return }
        activePlanEpoch = planEpoch
        statesByMediaUnitIndex.removeAll(keepingCapacity: false)
    }
}

#endif
