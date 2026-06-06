//
//  ScrollPhysicsCapturingView+Support.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
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

/// Scroll view that tracks whether native scroll physics began from direct touch or indirect pointer input.
final class InputSourceScrollView: CallbackScrollView {
    private var pendingInputSource: ScrollPhysicsCapturingView.InputSource?
    private var directTouchContactIdentifiers: Set<ObjectIdentifier> = []
    private(set) var activeInputSource: ScrollPhysicsCapturingView.InputSource = .indirectPointer

    var acceptsDirectTouchScroll = false {
        didSet {
            if !acceptsDirectTouchScroll, pendingInputSource == .directTouch {
                pendingInputSource = nil
            }
        }
    }

    var hasDirectInputSource: Bool {
        pendingInputSource == .directTouch || activeInputSource == .directTouch
    }

    var hasDirectTouchContact: Bool {
        !directTouchContactIdentifiers.isEmpty
    }

    /// Called when accepted direct-scroll touch input should wake the touch input path.
    var onDirectTouchActivity: (() -> Void)?

    /// Called when an accepted direct touch begins inside the scroll view.
    var onDirectTouchBegan: ((UITouch, Bool) -> Void)?

    /// Called when accepted direct-touch contacts finish or cancel.
    var onDirectTouchContactsEnded: ((Set<UITouch>, Bool) -> Void)?

    /// Called when stylus-like touches begin inside the scroll view.
    var onPencilTouchesBegan: ((Set<UITouch>) -> Void)?

    /// Called when stylus-like touches move, preserving the event used for coalesced samples.
    var onPencilTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)?

    /// Called when stylus-like touches finish.
    var onPencilTouchesEnded: ((Set<UITouch>) -> Void)?

    /// Called when stylus-like touches are cancelled.
    var onPencilTouchesCancelled: ((Set<UITouch>) -> Void)?

    func beginScrollingInputSource() -> ScrollPhysicsCapturingView.InputSource {
        activeInputSource = pendingInputSource ?? .indirectPointer
        pendingInputSource = nil
        return activeInputSource
    }

    func resetInputSource() {
        pendingInputSource = nil
        activeInputSource = .indirectPointer
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesBegan?(Set(pencilTouches))
        }

        let hadActiveDirectTouchContact = hasDirectTouchContact
        let directContactTouches = touches.filter { isDirectTouchContact($0) }
        directTouchContactIdentifiers.formUnion(directContactTouches.map(ObjectIdentifier.init))
        if acceptsDirectTouchScroll, !directContactTouches.isEmpty {
            pendingInputSource = .directTouch
            onDirectTouchActivity?()
            if directContactTouches.count == 1, let firstTouch = directContactTouches.first {
                onDirectTouchBegan?(firstTouch, hadActiveDirectTouchContact)
            }
        } else if touches.contains(where: isIndirectPointerTouch) {
            pendingInputSource = .indirectPointer
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
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
            updatePendingInputSource(from: nonPencilTouches)
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
            let directContactTouches = Set(nonPencilTouches.filter { isDirectTouchContact($0) })
            super.touchesEnded(Set(nonPencilTouches), with: event)
            removeDirectTouchContacts(from: nonPencilTouches)
            if !directContactTouches.isEmpty {
                onDirectTouchContactsEnded?(directContactTouches, hasDirectTouchContact)
            }
            pendingInputSource = nil
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesCancelled?(Set(pencilTouches))
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            let directContactTouches = Set(nonPencilTouches.filter { isDirectTouchContact($0) })
            super.touchesCancelled(Set(nonPencilTouches), with: event)
            removeDirectTouchContacts(from: nonPencilTouches)
            if !directContactTouches.isEmpty {
                onDirectTouchContactsEnded?(directContactTouches, hasDirectTouchContact)
            }
            pendingInputSource = nil
        }
    }

    private func updatePendingInputSource<Touches: Sequence>(
        from touches: Touches
    ) where Touches.Element == UITouch {
        let hasDirectTouch = touches.contains { isDirectTouchContact($0) }
        if acceptsDirectTouchScroll, hasDirectTouch {
            pendingInputSource = .directTouch
            return
        }

        if touches.contains(where: isIndirectPointerTouch) {
            pendingInputSource = .indirectPointer
        }
    }

    private func removeDirectTouchContacts<Touches: Sequence>(
        from touches: Touches
    ) where Touches.Element == UITouch {
        directTouchContactIdentifiers.subtract(touches
            .filter { isDirectTouchContact($0) }
            .map(ObjectIdentifier.init))
    }

    private func isDirectTouchContact(_ touch: UITouch) -> Bool {
        touch.type == .direct && !isStylusLikeTouch(touch)
    }

    private func isIndirectPointerTouch(_ touch: UITouch) -> Bool {
        (touch.type == .indirectPointer || touch.type == .indirect) && !isStylusLikeTouch(touch)
    }
}
#endif
