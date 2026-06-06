//
//  ScrollPhysicsCapturingView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(iOS) || os(visionOS)
import UIKit

/// Invisible scroll capture that forwards native scroll physics.
/// The actual content view stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
final class ScrollPhysicsCapturingView: UIView {
    /// Large offscreen scrollable area that allows native momentum before recentering.
    private static let scrollableSize: CGFloat = 100_000

    enum InputSource {
        case indirectPointer
        case directTouch
    }

    // MARK: - Safe Area Override

    var ignoresSafeArea: Bool = true {
        didSet {
            guard ignoresSafeArea != oldValue else { return }
            setNeedsLayout()
        }
    }

    override var safeAreaInsets: UIEdgeInsets {
        ignoresSafeArea ? .zero : super.safeAreaInsets
    }

    /// The invisible scroll view that captures direct-touch and indirect-pointer scroll physics.
    private let scrollView: InputSourceScrollView

    /// Dummy content view that scrollView scrolls (never visible).
    private let scrollContent: UIView

    /// The actual content we display (stays pinned to bounds)
    let contentView: UIView

    /// The pan recognizer that drives native one-finger direct-touch scrolling.
    var directTouchPanGestureRecognizer: UIPanGestureRecognizer { scrollView.panGestureRecognizer }

    /// Callback for scroll events: (deltaX, deltaY, phase, momentumPhase, source)
    var onScroll: ((CGFloat, CGFloat, MirageScrollPhase, MirageScrollPhase, InputSource) -> Void)?

    var isIndirectScrollActive: Bool {
        guard !scrollView.hasDirectTouchContact else { return false }
        guard scrollView.activeInputSource == .indirectPointer else { return false }
        return isScrollTracking ||
            scrollView.isTracking ||
            scrollView.isDragging ||
            scrollView.isDecelerating ||
            scrollView.panGestureRecognizer.state.isActive
    }

    /// Callback for rotation events: (rotationDegrees, phase)
    var onRotation: ((CGFloat, MirageScrollPhase) -> Void)?

    /// Whether direct one-finger touches should drive native scroll physics.
    var directTouchScrollEnabled: Bool = false {
        didSet {
            guard directTouchScrollEnabled != oldValue else { return }
            configureAllowedTouchTypes()
            if directTouchScrollEnabled {
                recenterIfNeeded(for: scrollView, force: true)
            } else {
                cancelDirectTouchScrolling()
                scrollView.resetInputSource()
            }
        }
    }

    /// Stops any in-progress momentum deceleration from indirect pointer scrolling.
    func stopIndirectScrollDeceleration() {
        guard scrollView.activeInputSource == .indirectPointer, scrollView.isDecelerating else { return }
        // Setting contentOffset to current offset stops momentum
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }

    /// Cancels direct-touch scrolling when a direct pointer gesture takes ownership.
    func cancelDirectTouchScrolling() {
        guard scrollView.hasDirectInputSource else { return }

        let currentOffset = scrollView.contentOffset
        if scrollView.isDecelerating {
            // Setting contentOffset to current offset stops momentum
            scrollView.setContentOffset(currentOffset, animated: false)
        }

        guard isScrollTracking || scrollView.panGestureRecognizer.state.isActive else {
            recenterIfNeeded(for: scrollView)
            scrollView.resetInputSource()
            return
        }

        scrollView.panGestureRecognizer.isEnabled = false
        scrollView.panGestureRecognizer.isEnabled = true
        setTracking(false)
        setLastContentOffset(currentOffset)
        recenterIfNeeded(for: scrollView)
        scrollView.resetInputSource()
    }

    /// Callback when accepted direct-scroll touch input is detected.
    var onDirectTouchActivity: (() -> Void)?

    /// Callback when a direct non-stylus touch begins scrolling, in this view's local coordinates.
    var onDirectTouchScrollBegan: ((CGPoint) -> Void)?

    /// Installs Pencil touch callbacks on the private scroll view.
    ///
    /// Only moved touches receive the `UIEvent` because coalesced touch samples are only read during movement.
    func configurePencilTouchHandlers(
        began: ((Set<UITouch>) -> Void)?,
        moved: ((Set<UITouch>, UIEvent?) -> Void)?,
        ended: ((Set<UITouch>) -> Void)?,
        cancelled: ((Set<UITouch>) -> Void)?
    ) {
        scrollView.onPencilTouchesBegan = began
        scrollView.onPencilTouchesMoved = moved
        scrollView.onPencilTouchesEnded = ended
        scrollView.onPencilTouchesCancelled = cancelled
    }

    /// Whether we're currently tracking a native scroll gesture.
    private var isScrollTracking = false

    /// Last content offset used to calculate scroll deltas.
    private var lastScrollContentOffset: CGPoint = .zero

    /// Flag to suppress scroll events during recenter operations.
    private var isRecenteringScroll = false

    /// Gesture recognizers for trackpad pinch/rotation
    private var rotationGesture: UIRotationGestureRecognizer!
    private let rotationGestureDelegate = RotationGestureDelegate()

    /// State tracking for incremental gesture deltas
    private var lastRotationAngle: CGFloat = 0.0

    override init(frame: CGRect) {
        scrollView = InputSourceScrollView(frame: frame)
        scrollContent = UIView()
        contentView = UIView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        scrollView = InputSourceScrollView()
        scrollContent = UIView()
        contentView = UIView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        insetsLayoutMarginsFromSafeArea = false

        bindScrollCallbacks(for: scrollView)
        configureScrollView(scrollView)
        configureAllowedTouchTypes()
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 1
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.onDirectTouchActivity = { [weak self] in
            self?.onDirectTouchActivity?()
        }

        setupScrollContent(scrollContent, in: scrollView)

        // Content view holds the actual sample-buffer view (stays pinned to our bounds)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Content view fills bounds
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Scroll view fills bounds
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Rotation gesture for trackpad (indirectPointer only)
        rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        rotationGestureDelegate.indirectPanGestureRecognizer = scrollView.panGestureRecognizer
        rotationGestureDelegate.rotationGestureRecognizer = rotationGesture
        rotationGesture.delegate = rotationGestureDelegate
        addGestureRecognizer(rotationGesture)
    }

    private func configureAllowedTouchTypes() {
        scrollView.acceptsDirectTouchScroll = directTouchScrollEnabled
        var allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
        ]
        if directTouchScrollEnabled {
            allowedTouchTypes.insert(NSNumber(value: UITouch.TouchType.direct.rawValue), at: 0)
        }
        scrollView.panGestureRecognizer.allowedTouchTypes = allowedTouchTypes
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
            self?.recenterIfNeeded(for: scrollView)
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
    }

    private func setupScrollContent(_ scrollContent: UIView, in scrollView: UIScrollView) {
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContent)
        scrollContent.frame = CGRect(x: 0, y: 0, width: Self.scrollableSize, height: Self.scrollableSize)
        scrollView.contentSize = CGSize(width: Self.scrollableSize, height: Self.scrollableSize)
    }

    override func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()

        recenterIfNeeded(for: scrollView, force: lastScrollContentOffset == .zero)
    }

    /// Center the scroll view's content offset
    /// - Parameters:
    ///   - scrollView: The scroll view to recenter.
    ///   - force: If true, recenter even if currently scrolling.
    private func recenterIfNeeded(for scrollView: UIScrollView, force: Bool = false) {
        let centerOffset = CGPoint(
            x: (Self.scrollableSize - bounds.width) / 2,
            y: (Self.scrollableSize - bounds.height) / 2
        )

        if force || (!isTracking && !scrollView.isDecelerating) {
            setRecentering(true)
            scrollView.contentOffset = centerOffset
            setLastContentOffset(centerOffset)
            setRecentering(false)
        }
    }

    // MARK: - Scroll Callbacks

    private func handleScrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        setTracking(true)
        setLastContentOffset(scrollView.contentOffset)
        let source = beginScrollingInputSource()
        if case .directTouch = source {
            onDirectTouchScrollBegan?(scrollStartLocation(for: scrollView))
        }
        onScroll?(0, 0, .began, .none, source)
    }

    private func handleScrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !isRecentering else { return }

        let currentOffset = scrollView.contentOffset
        let lastOffset = lastContentOffset

        // Calculate deltas (inverted: content moving left = scrolling right)
        let deltaX = lastOffset.x - currentOffset.x
        let deltaY = lastOffset.y - currentOffset.y
        setLastContentOffset(currentOffset)

        let phase: MirageScrollPhase = isTracking ? .changed : .none
        let momentumPhase: MirageScrollPhase = scrollView.isDecelerating ? .changed : .none

        if deltaX != 0 || deltaY != 0 {
            onScroll?(deltaX, deltaY, phase, momentumPhase, inputSource)
        }
    }

    private func handleScrollViewDidEndDragging(
        _ scrollView: UIScrollView,
        willDecelerate decelerate: Bool
    ) {
        let source = inputSource
        setTracking(false)

        if decelerate {
            onScroll?(0, 0, .ended, .began, source)
        } else {
            onScroll?(0, 0, .ended, .none, source)
            recenterIfNeeded(for: scrollView)
            resetInputSource()
        }
    }

    private func handleScrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        let source = inputSource
        onScroll?(0, 0, .none, .ended, source)
        recenterIfNeeded(for: scrollView)
        resetInputSource()
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

    private var isTracking: Bool {
        isScrollTracking
    }

    private var inputSource: InputSource {
        scrollView.activeInputSource
    }

    private func beginScrollingInputSource() -> InputSource {
        scrollView.beginScrollingInputSource()
    }

    private func scrollStartLocation(for scrollView: UIScrollView) -> CGPoint {
        let panGesture = scrollView.panGestureRecognizer
        let currentLocation = panGesture.location(in: self)
        let translation = panGesture.translation(in: self)
        return CGPoint(
            x: currentLocation.x - translation.x,
            y: currentLocation.y - translation.y
        )
    }

    private func resetInputSource() {
        scrollView.resetInputSource()
    }

    private func setTracking(_ isTracking: Bool) {
        isScrollTracking = isTracking
    }

    private var lastContentOffset: CGPoint {
        lastScrollContentOffset
    }

    private func setLastContentOffset(_ offset: CGPoint) {
        lastScrollContentOffset = offset
    }

    private var isRecentering: Bool {
        isRecenteringScroll
    }

    private func setRecentering(_ isRecentering: Bool) {
        isRecenteringScroll = isRecentering
    }
}

#endif
