//
//  MirageHostInputController+Scroll.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Host input controller extensions.
//

import Foundation
import CoreGraphics

#if os(macOS)
import AppKit
import ApplicationServices

extension MirageHostInputController {
    // MARK: - Scroll Event Injection (runs on accessibilityQueue)

    func injectScrollEvent(_ event: MirageScrollEvent, _ windowFrame: CGRect, app: MirageApplication?) {
        let scrollPoint: CGPoint
        if let normalizedLocation = event.location {
            scrollPoint = CGPoint(
                x: windowFrame.origin.x + normalizedLocation.x * windowFrame.width,
                y: windowFrame.origin.y + normalizedLocation.y * windowFrame.height
            )
        } else {
            scrollPoint = CGPoint(x: windowFrame.midX, y: windowFrame.midY)
        }

        guard let cgEvent = CGEvent(
            scrollWheelEvent2Source: nil,
            units: event.isPrecise ? .pixel : .line,
            wheelCount: 2,
            wheel1: Int32(event.deltaY),
            wheel2: Int32(event.deltaX),
            wheel3: 0
        ) else { return }

        cgEvent.location = scrollPoint
        cgEvent.flags = event.modifiers.cgEventFlags
        applyScrollFields(
            to: cgEvent,
            deltaX: event.deltaX,
            deltaY: event.deltaY,
            phase: event.phase,
            momentumPhase: event.momentumPhase,
            isPrecise: event.isPrecise
        )
        postEvent(cgEvent)
    }

}

private extension MirageHostInputController {
    func applyScrollFields(
        to cgEvent: CGEvent,
        deltaX: CGFloat,
        deltaY: CGFloat,
        phase: MirageScrollPhase,
        momentumPhase: MirageScrollPhase,
        isPrecise: Bool
    ) {
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: isPrecise ? 1 : 0)
        cgEvent.setIntegerValueField(
            .scrollWheelEventScrollPhase,
            value: Int64(phase.nsEventPhase.rawValue)
        )
        cgEvent.setIntegerValueField(
            .scrollWheelEventMomentumPhase,
            value: Int64(momentumPhase.nsEventPhase.rawValue)
        )

        guard isPrecise else { return }

        // Preserve sub-pixel deltas for trackpad-grade precision.
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(deltaY.rounded()))
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(deltaX.rounded()))
        cgEvent.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis1, value: fixedPoint(deltaY))
        cgEvent.setIntegerValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixedPoint(deltaX))
    }

    func fixedPoint(_ value: CGFloat) -> Int64 {
        Int64((value * 65_536).rounded(.towardZero))
    }
}

private extension MirageScrollPhase {
    var nsEventPhase: NSEvent.Phase {
        switch self {
        case .none:
            return []
        case .began:
            return .began
        case .changed:
            return .changed
        case .ended:
            return .ended
        case .cancelled:
            return .cancelled
        case .mayBegin:
            return .mayBegin
        }
    }
}

#endif
