//
//  MirageHostScrollEventFactory.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/7/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import CoreGraphics
import Foundation

#if os(macOS)
enum MirageHostScrollEventFactory {
    static func accumulatedIntegerDelta(for delta: CGFloat, remainder: inout CGFloat) -> Int32 {
        let rawDelta = delta + remainder
        let integerDelta = rawDelta.rounded(.towardZero)
        remainder = rawDelta - integerDelta
        return Int32(integerDelta)
    }

    static func makeScrollEvent(
        from event: MirageInput.MirageScrollEvent,
        integerDeltaX: Int32,
        integerDeltaY: Int32
    ) -> CGEvent? {
        let usesNativeScrollMetadata = event.hasNativeScrollMetadata
        guard integerDeltaX != 0 || integerDeltaY != 0 || usesNativeScrollMetadata else {
            return nil
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: integerDeltaY,
            wheel2: integerDeltaX,
            wheel3: 0
        ) else {
            return nil
        }

        if usesNativeScrollMetadata {
            applyNativeScrollMetadata(
                from: event,
                to: cgEvent
            )
        }
        return cgEvent
    }

    private static func applyNativeScrollMetadata(
        from event: MirageInput.MirageScrollEvent,
        to cgEvent: CGEvent
    ) {
        cgEvent.setIntegerValueField(
            .scrollWheelEventIsContinuous,
            value: event.isPrecise ? 1 : 0
        )
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: event.phase.cgScrollPhaseValue
        )
        cgEvent.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: event.momentumPhase.cgMomentumScrollPhaseValue
        )
    }
}

private extension MirageInput.MirageScrollPhase {
    var cgScrollPhaseValue: Int64 {
        switch self {
        case .none:
            0
        case .began:
            Int64(CGScrollPhase.began.rawValue)
        case .changed:
            Int64(CGScrollPhase.changed.rawValue)
        case .ended:
            Int64(CGScrollPhase.ended.rawValue)
        case .cancelled:
            Int64(CGScrollPhase.cancelled.rawValue)
        case .mayBegin:
            Int64(CGScrollPhase.mayBegin.rawValue)
        }
    }

    var cgMomentumScrollPhaseValue: Int64 {
        switch self {
        case .none,
             .mayBegin:
            Int64(CGMomentumScrollPhase.none.rawValue)
        case .began:
            Int64(CGMomentumScrollPhase.begin.rawValue)
        case .changed:
            Int64(CGMomentumScrollPhase.continuous.rawValue)
        case .ended,
             .cancelled:
            Int64(CGMomentumScrollPhase.end.rawValue)
        }
    }
}
#endif
