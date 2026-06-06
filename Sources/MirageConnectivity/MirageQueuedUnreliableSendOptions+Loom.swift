//
//  MirageQueuedUnreliableSendOptions+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom

package struct MirageQueuedUnreliableSendOptions: Sendable, Codable, Equatable {
    package enum Importance: String, Sendable, Codable, Equatable {
        case realtimeKeyframe
        case realtimeParity
        case realtimeRecovery
        case realtimeInterFrame
    }

    package let deadlineUptime: TimeInterval?
    package let importance: Importance
    package let frameID: UInt64?
    package let fragmentIndex: Int?
    package let fragmentCount: Int?
    package let dropsWhenExpired: Bool
    package let dropsWhenQueueFull: Bool

    package init(
        deadlineUptime: TimeInterval? = nil,
        importance: Importance,
        frameID: UInt64? = nil,
        fragmentIndex: Int? = nil,
        fragmentCount: Int? = nil,
        dropsWhenExpired: Bool,
        dropsWhenQueueFull: Bool
    ) {
        self.deadlineUptime = deadlineUptime
        self.importance = importance
        self.frameID = frameID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.dropsWhenExpired = dropsWhenExpired
        self.dropsWhenQueueFull = dropsWhenQueueFull
    }
}

extension LoomQueuedUnreliableSendOptions {
    package init(mirageOptions options: MirageQueuedUnreliableSendOptions) {
        self.init(
            deadlineUptime: options.deadlineUptime,
            importance: Importance(mirageImportance: options.importance),
            frameID: options.frameID,
            fragmentIndex: options.fragmentIndex,
            fragmentCount: options.fragmentCount,
            dropsWhenExpired: options.dropsWhenExpired,
            dropsWhenQueueFull: options.dropsWhenQueueFull
        )
    }
}

private extension LoomQueuedUnreliableSendOptions.Importance {
    init(mirageImportance importance: MirageQueuedUnreliableSendOptions.Importance) {
        self = switch importance {
        case .realtimeKeyframe:
            .realtimeKeyframe
        case .realtimeParity:
            .realtimeParity
        case .realtimeRecovery:
            .realtimeRecovery
        case .realtimeInterFrame:
            .realtimeInterFrame
        }
    }
}
