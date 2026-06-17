//
//  MirageInputEvent+SenderClassification.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageKit

extension MirageInputEvent {
    /// Whether the scroll event carries native phase metadata used for merge decisions.
    var hasNativeScrollMetadata: Bool {
        guard case let .scrollWheel(event) = self else { return false }
        return event.hasNativeScrollMetadata
    }

    /// Returns a merged native continuous scroll event when two adjacent events are compatible.
    func mergedWithCompatibleNativeContinuousScrollEvent(_ newerEvent: MirageInputEvent) -> MirageInputEvent? {
        guard case let .scrollWheel(scrollEvent) = self,
              case let .scrollWheel(newerScrollEvent) = newerEvent,
              let mergedEvent = scrollEvent.mergedWithCompatibleNativeContinuousScrollEvent(newerScrollEvent) else {
            return nil
        }
        return .scrollWheel(mergedEvent)
    }

    /// Whether this event counts as user activity for automatic stream probe gating.
    var shouldGateAutomaticProbe: Bool {
        switch self {
        case .keyDown,
             .keyUp,
             .flagsChanged,
             .mouseDown,
             .mouseUp,
             .mouseMoved,
             .mouseDragged,
             .pointerSampleBatch,
             .rightMouseDown,
             .rightMouseUp,
             .rightMouseDragged,
             .otherMouseDown,
             .otherMouseUp,
             .otherMouseDragged,
             .scrollWheel:
            true
        case .hostSystemAction,
             .magnify,
             .pixelResize,
             .relativeResize,
             .rotate,
             .swipe,
             .windowFocus,
             .windowResize:
            false
        }
    }
}
