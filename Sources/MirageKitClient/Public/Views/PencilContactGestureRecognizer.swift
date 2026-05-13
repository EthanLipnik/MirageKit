//
//  PencilContactGestureRecognizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/29/26.
//

#if os(iOS) || os(visionOS)
import UIKit

/// Gesture recognizer that forwards stylus-like touches before direct-touch scrolling handles them.
final class PencilContactGestureRecognizer: UIGestureRecognizer {
    /// Overrides the platform Pencil classification for direct touches with stylus metadata.
    var isStylusTouch: ((UITouch) -> Bool)?

    /// Called when one or more stylus touches begin tracking.
    var onTouchesBegan: ((Set<UITouch>) -> Void)?

    /// Called when tracked stylus touches move, preserving the event used for coalesced samples.
    var onTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)?

    /// Called when tracked stylus touches finish.
    var onTouchesEnded: ((Set<UITouch>) -> Void)?

    /// Called when tracked stylus touches are cancelled.
    var onTouchesCancelled: ((Set<UITouch>) -> Void)?

    private var activeStylusTouches = Set<UITouch>()

    override func canPrevent(_: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let stylusTouches = touches.filter(isStylus)
        guard !stylusTouches.isEmpty else { return }

        activeStylusTouches.formUnion(stylusTouches)
        onTouchesBegan?(Set(stylusTouches))
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let newlyDetectedStylusTouches = touches.filter { touch in
            isStylus(touch) && !activeStylusTouches.contains(touch)
        }
        if !newlyDetectedStylusTouches.isEmpty {
            activeStylusTouches.formUnion(newlyDetectedStylusTouches)
            onTouchesBegan?(Set(newlyDetectedStylusTouches))
            if state == .possible { state = .began }
        }

        let movedStylusTouches = touches.filter { activeStylusTouches.contains($0) }
        guard !movedStylusTouches.isEmpty else { return }

        onTouchesMoved?(Set(movedStylusTouches), event)
        if state == .possible {
            state = .began
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let endedStylusTouches = touches.filter { activeStylusTouches.contains($0) }
        guard !endedStylusTouches.isEmpty else {
            if activeStylusTouches.isEmpty { state = .failed }
            return
        }

        onTouchesEnded?(Set(endedStylusTouches))
        activeStylusTouches.subtract(endedStylusTouches)
        state = activeStylusTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let cancelledStylusTouches = touches.filter { activeStylusTouches.contains($0) }
        guard !cancelledStylusTouches.isEmpty else {
            if activeStylusTouches.isEmpty { state = .failed }
            return
        }

        onTouchesCancelled?(Set(cancelledStylusTouches))
        activeStylusTouches.subtract(cancelledStylusTouches)
        state = activeStylusTouches.isEmpty ? .cancelled : .changed
    }

    override func reset() {
        activeStylusTouches.removeAll()
    }

    private func isStylus(_ touch: UITouch) -> Bool {
        isStylusTouch?(touch) ?? (touch.type == .pencil)
    }
}
#endif
