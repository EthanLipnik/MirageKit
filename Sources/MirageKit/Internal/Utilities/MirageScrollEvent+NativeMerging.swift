//
//  MirageScrollEvent+NativeMerging.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

package extension MirageScrollEvent {
    /// Whether the event includes native scroll phase or momentum phase metadata.
    var hasNativeScrollMetadata: Bool {
        phase != .none || momentumPhase != .none
    }

    /// Whether the event starts, ends, or cancels a scroll or momentum-scroll sequence.
    var isBoundaryScrollEvent: Bool {
        phase == .began || phase == .ended || phase == .cancelled
            || momentumPhase == .began || momentumPhase == .ended || momentumPhase == .cancelled
    }

    /// Whether this event can be coalesced with a newer continuous native scroll update.
    var isMergeableNativeContinuousScrollEvent: Bool {
        hasNativeScrollMetadata
            && !isBoundaryScrollEvent
            && (phase == .changed || momentumPhase == .changed)
    }

    /// Returns a single event that accumulates compatible native continuous scroll deltas.
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
