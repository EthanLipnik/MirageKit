//
//  MirageScrollEvent+NativeMerging.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

import Foundation

package extension MirageScrollEvent {
    var hasNativeScrollMetadata: Bool {
        phase != .none || momentumPhase != .none
    }

    var isBoundaryScrollEvent: Bool {
        phase == .began || phase == .ended || phase == .cancelled
            || momentumPhase == .began || momentumPhase == .ended || momentumPhase == .cancelled
    }

    var isMergeableNativeContinuousScrollEvent: Bool {
        hasNativeScrollMetadata
            && !isBoundaryScrollEvent
            && (phase == .changed || momentumPhase == .changed)
    }

    func mergedWithCompatibleNativeContinuousScrollEvent(
        _ newerEvent: MirageScrollEvent
    ) -> MirageScrollEvent? {
        guard isMergeableNativeContinuousScrollEvent,
              newerEvent.isMergeableNativeContinuousScrollEvent,
              location == newerEvent.location,
              modifiers == newerEvent.modifiers,
              isPrecise == newerEvent.isPrecise else {
            return nil
        }

        return MirageScrollEvent(
            deltaX: deltaX + newerEvent.deltaX,
            deltaY: deltaY + newerEvent.deltaY,
            location: newerEvent.location,
            phase: newerEvent.phase,
            momentumPhase: newerEvent.momentumPhase,
            modifiers: newerEvent.modifiers,
            isPrecise: newerEvent.isPrecise,
            timestamp: newerEvent.timestamp
        )
    }
}
