//
//  DirectTouchContactGestureRecognizer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/7/26.
//

#if os(iOS) || os(visionOS)
import UIKit

/// Passive recognizer that reports direct finger contact boundaries without taking gesture ownership.
final class DirectTouchContactGestureRecognizer: UIGestureRecognizer {
    var isAcceptedDirectTouch: ((UITouch) -> Bool)?
    var onTouchesBegan: ((Set<UITouch>, Bool) -> Void)?
    var onTouchesEnded: ((Set<UITouch>, Bool) -> Void)?
    var onTouchesCancelled: ((Set<UITouch>, Bool) -> Void)?

    private var activeDirectTouches = Set<UITouch>()

    override func canPrevent(_: UIGestureRecognizer) -> Bool {
        false
    }

    override func canBePrevented(by _: UIGestureRecognizer) -> Bool {
        false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let directTouches = touches.filter(isAcceptedDirectContact)
        guard !directTouches.isEmpty else { return }

        let hadActiveDirectTouchContact = !activeDirectTouches.isEmpty
        activeDirectTouches.formUnion(directTouches)
        onTouchesBegan?(Set(directTouches), hadActiveDirectTouchContact)
        state = state == .possible ? .began : .changed
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        let endedTouches = touches.filter { activeDirectTouches.contains($0) }
        guard !endedTouches.isEmpty else {
            if activeDirectTouches.isEmpty { state = .failed }
            return
        }

        activeDirectTouches.subtract(endedTouches)
        onTouchesEnded?(Set(endedTouches), !activeDirectTouches.isEmpty)
        state = activeDirectTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        let cancelledTouches = touches.filter { activeDirectTouches.contains($0) }
        guard !cancelledTouches.isEmpty else {
            if activeDirectTouches.isEmpty { state = .failed }
            return
        }

        activeDirectTouches.subtract(cancelledTouches)
        onTouchesCancelled?(Set(cancelledTouches), !activeDirectTouches.isEmpty)
        state = activeDirectTouches.isEmpty ? .cancelled : .changed
    }

    override func reset() {
        activeDirectTouches.removeAll()
    }

    private func isAcceptedDirectContact(_ touch: UITouch) -> Bool {
        isAcceptedDirectTouch?(touch) ?? (touch.type == .direct)
    }
}
#endif
