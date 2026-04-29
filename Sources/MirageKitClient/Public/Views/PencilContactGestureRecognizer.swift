//
//  PencilContactGestureRecognizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/29/26.
//

#if os(iOS) || os(visionOS)
import UIKit

final class PencilContactGestureRecognizer: UIGestureRecognizer {
    var isStylusTouch: ((UITouch) -> Bool)?
    var onTouchesBegan: ((Set<UITouch>, UIEvent?) -> Void)?
    var onTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)?
    var onTouchesEnded: ((Set<UITouch>, UIEvent?) -> Void)?
    var onTouchesCancelled: ((Set<UITouch>, UIEvent?) -> Void)?

    private var activeStylusTouches = Set<UITouch>()

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let stylusTouches = touches.filter(isStylus)
        guard !stylusTouches.isEmpty else { return }

        activeStylusTouches.formUnion(stylusTouches)
        onTouchesBegan?(Set(stylusTouches), event)
        state = state == .possible ? .began : .changed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let newlyDetectedStylusTouches = touches.filter { touch in
            isStylus(touch) && !activeStylusTouches.contains(touch)
        }
        if !newlyDetectedStylusTouches.isEmpty {
            activeStylusTouches.formUnion(newlyDetectedStylusTouches)
            onTouchesBegan?(Set(newlyDetectedStylusTouches), event)
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

        onTouchesEnded?(Set(endedStylusTouches), event)
        activeStylusTouches.subtract(endedStylusTouches)
        state = activeStylusTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let cancelledStylusTouches = touches.filter { activeStylusTouches.contains($0) }
        guard !cancelledStylusTouches.isEmpty else {
            if activeStylusTouches.isEmpty { state = .failed }
            return
        }

        onTouchesCancelled?(Set(cancelledStylusTouches), event)
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
