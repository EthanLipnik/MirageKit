//
//  ScrollPhysicsCapturingView+Support.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(iOS) || os(visionOS)
import UIKit

extension UIGestureRecognizer.State {
    /// Whether the gesture is actively producing changes.
    var isActive: Bool {
        switch self {
        case .began, .changed:
            true
        default:
            false
        }
    }
}

/// Allows indirect pan and rotation gestures to recognize together for trackpad input.
final class RotationGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    weak var indirectPanGestureRecognizer: UIGestureRecognizer?
    weak var rotationGestureRecognizer: UIGestureRecognizer?

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard let indirectPanGestureRecognizer, let rotationGestureRecognizer else {
            return false
        }
        return (gestureRecognizer == indirectPanGestureRecognizer && otherGestureRecognizer == rotationGestureRecognizer) ||
            (gestureRecognizer == rotationGestureRecognizer && otherGestureRecognizer == indirectPanGestureRecognizer)
    }
}

/// UIScrollView delegate bridge that keeps `CallbackScrollView` in control of delegate ownership.
final class CallbackScrollViewDelegateProxy: NSObject, UIScrollViewDelegate {
    weak var owner: CallbackScrollView?

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        owner?.onWillBeginDragging?(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        owner?.onDidScroll?(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        owner?.onDidEndDragging?(scrollView, decelerate)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        owner?.onDidEndDecelerating?(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        owner?.onDidEndScrollingAnimation?(scrollView)
    }
}

/// Scroll view that exposes delegate callbacks as closures.
class CallbackScrollView: UIScrollView {
    var onWillBeginDragging: ((UIScrollView) -> Void)?
    var onDidScroll: ((UIScrollView) -> Void)?
    var onDidEndDragging: ((UIScrollView, Bool) -> Void)?
    var onDidEndDecelerating: ((UIScrollView) -> Void)?
    var onDidEndScrollingAnimation: ((UIScrollView) -> Void)?
    private let delegateProxy = CallbackScrollViewDelegateProxy()

    private func installDelegateBindings() {
        delegateProxy.owner = self
        if (super.delegate as AnyObject?) !== delegateProxy {
            super.delegate = delegateProxy
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installDelegateBindings()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installDelegateBindings()
    }
}

/// Returns whether a UIKit touch should be routed to Pencil handling instead of scroll physics.
func isStylusLikeTouch(_ touch: UITouch) -> Bool {
    if touch.type == .pencil { return true }
    guard touch.type == .direct else { return false }
    return touch.maximumPossibleForce > 1.0 ||
        touch.force > 1.0 ||
        touch.estimatedProperties.contains(.force) ||
        touch.estimatedProperties.contains(.azimuth) ||
        touch.estimatedProperties.contains(.altitude) ||
        touch.estimatedPropertiesExpectingUpdates.contains(.force) ||
        touch.estimatedPropertiesExpectingUpdates.contains(.azimuth) ||
        touch.estimatedPropertiesExpectingUpdates.contains(.altitude)
}

/// Direct-touch scroll view that separates Pencil/stylus touches from one-finger scroll input.
final class DirectTouchScrollView: CallbackScrollView {
    /// Called when direct non-stylus input should wake the touch input path.
    var onDirectTouchActivity: (() -> Void)?

    /// Called when stylus-like touches begin inside the direct-touch scroll view.
    var onPencilTouchesBegan: ((Set<UITouch>) -> Void)?

    /// Called when stylus-like touches move, preserving the event used for coalesced samples.
    var onPencilTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)?

    /// Called when stylus-like touches finish.
    var onPencilTouchesEnded: ((Set<UITouch>) -> Void)?

    /// Called when stylus-like touches are cancelled.
    var onPencilTouchesCancelled: ((Set<UITouch>) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesBegan?(Set(pencilTouches))
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            onDirectTouchActivity?()
        }
        if !nonPencilTouches.isEmpty {
            super.touchesBegan(Set(nonPencilTouches), with: event)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesMoved?(Set(pencilTouches), event)
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            super.touchesMoved(Set(nonPencilTouches), with: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesEnded?(Set(pencilTouches))
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            super.touchesEnded(Set(nonPencilTouches), with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesCancelled?(Set(pencilTouches))
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            super.touchesCancelled(Set(nonPencilTouches), with: event)
        }
    }
}
#endif
