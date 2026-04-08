//
//  ScrollPhysicsCapturingView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

/// Invisible scroll views that capture native scroll physics.
/// The actual content (Metal view) stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
final class ScrollPhysicsCapturingView: UIView {
    // MARK: - Safe Area Override

    /// Override safe area insets to ensure content fills entire screen
    override var safeAreaInsets: UIEdgeInsets { .zero }

    /// The invisible scroll view for indirect pointer / trackpad physics
    private let indirectScrollView: CallbackScrollView

    /// The invisible scroll view for direct-touch physics
    private let directTouchScrollView: LocationReportingScrollView

    /// Dummy content view that indirectScrollView scrolls (never visible)
    private let indirectScrollContent: UIView

    /// Dummy content view that directTouchScrollView scrolls (never visible)
    private let directTouchScrollContent: UIView

    /// The actual content we display (stays pinned to bounds)
    let contentView: UIView

    /// The pan recognizer that drives native one-finger direct-touch scrolling.
    var directTouchPanGestureRecognizer: UIPanGestureRecognizer { directTouchScrollView.panGestureRecognizer }

    /// Callback for scroll events: (deltaX, deltaY, phase, momentumPhase)
    var onScroll: ((CGFloat, CGFloat, MirageScrollPhase, MirageScrollPhase) -> Void)?

    /// Callback for rotation events: (rotationDegrees, phase)
    var onRotation: ((CGFloat, MirageScrollPhase) -> Void)?

    /// Whether direct one-finger touches should drive native scroll physics.
    var directTouchScrollEnabled: Bool = false {
        didSet {
            guard directTouchScrollEnabled != oldValue else { return }
            directTouchScrollView.isUserInteractionEnabled = directTouchScrollEnabled
            directTouchScrollView.isHidden = !directTouchScrollEnabled
            if directTouchScrollEnabled {
                recenterIfNeeded(for: directTouchScrollView, force: true)
            } else {
                stopTracking(for: directTouchScrollView)
            }
        }
    }

    /// Stops any in-progress momentum deceleration on the indirect scroll view.
    func stopIndirectScrollDeceleration() {
        guard indirectScrollView.isDecelerating else { return }
        // Setting contentOffset to current offset stops momentum
        indirectScrollView.setContentOffset(indirectScrollView.contentOffset, animated: false)
    }

    /// Callback when a direct non-stylus touch is detected.
    var onDirectTouchActivity: (() -> Void)?

    /// Callback when direct-touch contact location changes.
    var onDirectTouchLocationChanged: ((CGPoint) -> Void)?

    var onPencilTouchesBegan: ((Set<UITouch>, UIEvent?) -> Void)? {
        get { directTouchScrollView.onPencilTouchesBegan }
        set { directTouchScrollView.onPencilTouchesBegan = newValue }
    }

    var onPencilTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)? {
        get { directTouchScrollView.onPencilTouchesMoved }
        set { directTouchScrollView.onPencilTouchesMoved = newValue }
    }

    var onPencilTouchesEnded: ((Set<UITouch>, UIEvent?) -> Void)? {
        get { directTouchScrollView.onPencilTouchesEnded }
        set { directTouchScrollView.onPencilTouchesEnded = newValue }
    }

    var onPencilTouchesCancelled: ((Set<UITouch>, UIEvent?) -> Void)? {
        get { directTouchScrollView.onPencilTouchesCancelled }
        set { directTouchScrollView.onPencilTouchesCancelled = newValue }
    }

    /// Size of scrollable area - large enough for extended scrolling before recenter
    private let scrollableSize: CGFloat = 100_000

    /// Whether we're currently tracking a gesture in the indirect scroll view
    private var isIndirectTracking = false

    /// Whether we're currently tracking a gesture in the direct scroll view
    private var isDirectTracking = false

    /// Last content offset for the indirect scroll view
    private var lastIndirectContentOffset: CGPoint = .zero

    /// Last content offset for the direct scroll view
    private var lastDirectContentOffset: CGPoint = .zero

    /// Flag to suppress scroll events during indirect recenter operation
    private var isRecenteringIndirect = false

    /// Flag to suppress scroll events during direct recenter operation
    private var isRecenteringDirect = false

    /// Gesture recognizers for trackpad pinch/rotation
    private var rotationGesture: UIRotationGestureRecognizer!
    private let rotationGestureDelegate = RotationGestureDelegate()

    /// State tracking for incremental gesture deltas
    private var lastRotationAngle: CGFloat = 0.0

    override init(frame: CGRect) {
        indirectScrollView = CallbackScrollView(frame: frame)
        directTouchScrollView = LocationReportingScrollView(frame: frame)
        indirectScrollContent = UIView()
        directTouchScrollContent = UIView()
        contentView = UIView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        indirectScrollView = CallbackScrollView()
        directTouchScrollView = LocationReportingScrollView()
        indirectScrollContent = UIView()
        directTouchScrollContent = UIView()
        contentView = UIView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Ensure this view doesn't respect safe area insets
        insetsLayoutMarginsFromSafeArea = false

        bindScrollCallbacks(for: indirectScrollView)
        bindScrollCallbacks(for: directTouchScrollView)
        configureScrollView(indirectScrollView)
        configureScrollView(directTouchScrollView)

        indirectScrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]

        directTouchScrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
        ]
        directTouchScrollView.panGestureRecognizer.minimumNumberOfTouches = 1
        directTouchScrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        directTouchScrollView.isUserInteractionEnabled = false
        directTouchScrollView.isHidden = true
        directTouchScrollView.onDirectTouchActivity = { [weak self] in
            self?.onDirectTouchActivity?()
        }
        directTouchScrollView.onTouchLocationChanged = { [weak self] rawLocation in
            self?.onDirectTouchLocationChanged?(rawLocation)
        }

        setupScrollContent(indirectScrollContent, in: indirectScrollView)
        setupScrollContent(directTouchScrollContent, in: directTouchScrollView)

        // Content view holds the actual Metal view (stays pinned to our bounds)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        addSubview(indirectScrollView)
        addSubview(directTouchScrollView)

        NSLayoutConstraint.activate([
            // Content view fills bounds
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Scroll views fill bounds
            indirectScrollView.topAnchor.constraint(equalTo: topAnchor),
            indirectScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            indirectScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            indirectScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            directTouchScrollView.topAnchor.constraint(equalTo: topAnchor),
            directTouchScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            directTouchScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            directTouchScrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Rotation gesture for trackpad (indirectPointer only)
        rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        rotationGestureDelegate.indirectPanGestureRecognizer = indirectScrollView.panGestureRecognizer
        rotationGestureDelegate.rotationGestureRecognizer = rotationGesture
        rotationGesture.delegate = rotationGestureDelegate
        addGestureRecognizer(rotationGesture)
    }

    private func bindScrollCallbacks(for scrollView: CallbackScrollView) {
        scrollView.onWillBeginDragging = { [weak self] scrollView in
            self?.handleScrollViewWillBeginDragging(scrollView)
        }
        scrollView.onDidScroll = { [weak self] scrollView in
            self?.handleScrollViewDidScroll(scrollView)
        }
        scrollView.onDidEndDragging = { [weak self] scrollView, willDecelerate in
            self?.handleScrollViewDidEndDragging(scrollView, willDecelerate: willDecelerate)
        }
        scrollView.onDidEndDecelerating = { [weak self] scrollView in
            self?.handleScrollViewDidEndDecelerating(scrollView)
        }
        scrollView.onDidEndScrollingAnimation = { [weak self] scrollView in
            self?.handleScrollViewDidEndScrollingAnimation(scrollView)
        }
    }

    private func configureScrollView(_ scrollView: CallbackScrollView) {
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false
        scrollView.panGestureRecognizer.delegate = scrollView
    }

    private func setupScrollContent(_ scrollContent: UIView, in scrollView: UIScrollView) {
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContent)
        scrollContent.frame = CGRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize)
        scrollView.contentSize = CGSize(width: scrollableSize, height: scrollableSize)
    }

    override func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()

        recenterIfNeeded(for: indirectScrollView, force: lastIndirectContentOffset == .zero)
        if directTouchScrollEnabled {
            recenterIfNeeded(for: directTouchScrollView, force: lastDirectContentOffset == .zero)
        }
    }

    /// Center the scroll view's content offset
    /// - Parameters:
    ///   - scrollView: The scroll view to recenter.
    ///   - force: If true, recenter even if currently scrolling.
    private func recenterIfNeeded(for scrollView: UIScrollView, force: Bool = false) {
        let centerOffset = CGPoint(
            x: (scrollableSize - bounds.width) / 2,
            y: (scrollableSize - bounds.height) / 2
        )

        if force || (!isTracking(scrollView) && !scrollView.isDecelerating) {
            setRecentering(true, for: scrollView)
            scrollView.contentOffset = centerOffset
            setLastContentOffset(centerOffset, for: scrollView)
            setRecentering(false, for: scrollView)
        }
    }

    // MARK: - Scroll Callbacks

    private func handleScrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setTracking(true, for: scrollView)
        setLastContentOffset(scrollView.contentOffset, for: scrollView)
        reportDirectTouchPanLocation(for: scrollView)
        onScroll?(0, 0, .began, .none)
    }

    private func handleScrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRecentering(scrollView) else { return }

        // Update cursor position from pan gesture during active direct-touch scrolling
        // so the host cursor follows the finger and scroll events target the right area.
        reportDirectTouchPanLocation(for: scrollView)

        let currentOffset = scrollView.contentOffset
        let lastOffset = lastContentOffset(for: scrollView)

        // Calculate deltas (inverted: content moving left = scrolling right)
        let deltaX = lastOffset.x - currentOffset.x
        let deltaY = lastOffset.y - currentOffset.y
        setLastContentOffset(currentOffset, for: scrollView)

        let phase: MirageScrollPhase = isTracking(scrollView) ? .changed : .none
        let momentumPhase: MirageScrollPhase = scrollView.isDecelerating ? .changed : .none

        if deltaX != 0 || deltaY != 0 {
            onScroll?(deltaX, deltaY, phase, momentumPhase)
        }
    }

    private func reportDirectTouchPanLocation(for scrollView: UIScrollView) {
        guard scrollView === directTouchScrollView, isDirectTracking else { return }
        let referenceView = superview ?? self
        let panLocation = directTouchScrollView.panGestureRecognizer.location(in: referenceView)
        onDirectTouchLocationChanged?(panLocation)
    }

    private func handleScrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        setTracking(false, for: scrollView)

        if !decelerate {
            onScroll?(0, 0, .ended, .none)
            recenterIfNeeded(for: scrollView)
        }
    }

    private func handleScrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onScroll?(0, 0, .none, .ended)
        recenterIfNeeded(for: scrollView)
    }

    private func handleScrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        recenterIfNeeded(for: scrollView)
    }

    // MARK: - Trackpad Gesture Handlers

    @objc
    private func handleRotation(_ gesture: UIRotationGestureRecognizer) {
        let phase = MirageScrollPhase(gestureState: gesture.state)

        switch gesture.state {
        case .began:
            lastRotationAngle = 0
            onRotation?(0, phase)

        case .changed:
            // Convert radians to degrees for the delta
            let rotationDelta = (gesture.rotation - lastRotationAngle) * (180.0 / .pi)
            lastRotationAngle = gesture.rotation
            onRotation?(rotationDelta, phase)

        case .cancelled,
             .ended:
            onRotation?(0, phase)
            lastRotationAngle = 0

        default:
            break
        }
    }

    private func isTracking(_ scrollView: UIScrollView) -> Bool {
        if scrollView === indirectScrollView { return isIndirectTracking }
        return isDirectTracking
    }

    private func setTracking(_ isTracking: Bool, for scrollView: UIScrollView) {
        if scrollView === indirectScrollView {
            isIndirectTracking = isTracking
        } else {
            isDirectTracking = isTracking
        }
    }

    private func stopTracking(for scrollView: UIScrollView) {
        setTracking(false, for: scrollView)
        setRecentering(false, for: scrollView)
        scrollView.setContentOffset(lastContentOffset(for: scrollView), animated: false)
    }

    private func lastContentOffset(for scrollView: UIScrollView) -> CGPoint {
        if scrollView === indirectScrollView { return lastIndirectContentOffset }
        return lastDirectContentOffset
    }

    private func setLastContentOffset(_ offset: CGPoint, for scrollView: UIScrollView) {
        if scrollView === indirectScrollView {
            lastIndirectContentOffset = offset
        } else {
            lastDirectContentOffset = offset
        }
    }

    private func isRecentering(_ scrollView: UIScrollView) -> Bool {
        if scrollView === indirectScrollView { return isRecenteringIndirect }
        return isRecenteringDirect
    }

    private func setRecentering(_ isRecentering: Bool, for scrollView: UIScrollView) {
        if scrollView === indirectScrollView {
            isRecenteringIndirect = isRecentering
        } else {
            isRecenteringDirect = isRecentering
        }
    }
}

private final class RotationGestureDelegate: NSObject, UIGestureRecognizerDelegate {
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

private class CallbackScrollView: UIScrollView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onWillBeginDragging: ((UIScrollView) -> Void)?
    var onDidScroll: ((UIScrollView) -> Void)?
    var onDidEndDragging: ((UIScrollView, Bool) -> Void)?
    var onDidEndDecelerating: ((UIScrollView) -> Void)?
    var onDidEndScrollingAnimation: ((UIScrollView) -> Void)?

    private func installDelegateBindingsIfNeeded() {
        if (super.delegate as AnyObject?) !== self {
            super.delegate = self
        }
        if (panGestureRecognizer.delegate as AnyObject?) !== self {
            panGestureRecognizer.delegate = self
        }
    }

    private func clearDelegateBindingsIfNeeded() {
        if (super.delegate as AnyObject?) === self {
            super.delegate = nil
        }
        if (panGestureRecognizer.delegate as AnyObject?) === self {
            panGestureRecognizer.delegate = nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        installDelegateBindingsIfNeeded()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        installDelegateBindingsIfNeeded()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            setContentOffset(contentOffset, animated: false)
            layer.removeAllAnimations()
            clearDelegateBindingsIfNeeded()
        }
        super.willMove(toWindow: newWindow)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil {
            installDelegateBindingsIfNeeded()
        }
    }

    deinit {
        clearDelegateBindingsIfNeeded()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        onWillBeginDragging?(scrollView)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        onDidScroll?(scrollView)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        onDidEndDragging?(scrollView, decelerate)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        onDidEndDecelerating?(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        onDidEndScrollingAnimation?(scrollView)
    }
}

private func isStylusLikeTouch(_ touch: UITouch) -> Bool {
    if touch.type == .pencil { return true }
    guard touch.type == .direct else { return false }
    if touch.maximumPossibleForce > 1.0 { return true }
    if touch.force > 1.0 { return true }
    if touch.estimatedProperties.contains(.force) ||
        touch.estimatedProperties.contains(.azimuth) ||
        touch.estimatedProperties.contains(.altitude) {
        return true
    }
    if touch.estimatedPropertiesExpectingUpdates.contains(.force) ||
        touch.estimatedPropertiesExpectingUpdates.contains(.azimuth) ||
        touch.estimatedPropertiesExpectingUpdates.contains(.altitude) {
        return true
    }
    return false
}

private final class LocationReportingScrollView: CallbackScrollView {
    var onDirectTouchActivity: (() -> Void)?
    var onTouchLocationChanged: ((CGPoint) -> Void)?
    var onPencilTouchesBegan: ((Set<UITouch>, UIEvent?) -> Void)?
    var onPencilTouchesMoved: ((Set<UITouch>, UIEvent?) -> Void)?
    var onPencilTouchesEnded: ((Set<UITouch>, UIEvent?) -> Void)?
    var onPencilTouchesCancelled: ((Set<UITouch>, UIEvent?) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesBegan?(Set(pencilTouches), event)
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            onDirectTouchActivity?()
        }
        reportLocation(for: Set(nonPencilTouches))
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
        reportLocation(for: Set(nonPencilTouches))
        if !nonPencilTouches.isEmpty {
            super.touchesMoved(Set(nonPencilTouches), with: event)
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesEnded?(Set(pencilTouches), event)
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        reportLocation(for: Set(nonPencilTouches))
        if !nonPencilTouches.isEmpty {
            super.touchesEnded(Set(nonPencilTouches), with: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        let pencilTouches = touches.filter { isStylusLikeTouch($0) }
        if !pencilTouches.isEmpty {
            onPencilTouchesCancelled?(Set(pencilTouches), event)
        }

        let nonPencilTouches = touches.filter { !isStylusLikeTouch($0) }
        if !nonPencilTouches.isEmpty {
            super.touchesCancelled(Set(nonPencilTouches), with: event)
        }
    }

    private func reportLocation(for touches: Set<UITouch>) {
        guard let touch = touches.first else { return }
        onTouchLocationChanged?(touch.preciseLocation(in: superview))
    }
}
#endif
