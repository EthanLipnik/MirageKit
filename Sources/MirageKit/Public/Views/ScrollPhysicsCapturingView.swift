//
//  ScrollPhysicsCapturingView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import UIKit

/// Invisible scroll view that captures native trackpad scroll physics.
/// The actual content (Metal view) stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
final class ScrollPhysicsCapturingView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    // MARK: - Safe Area Override

    /// Override safe area insets to ensure content fills entire screen
    override var safeAreaInsets: UIEdgeInsets { .zero }

    /// The invisible scroll view for capturing trackpad physics
    let scrollView: UIScrollView

    /// Dummy content view that scrollView scrolls (never visible)
    private let scrollContent: UIView

    /// The actual content we display (stays pinned to bounds)
    let contentView: UIView

    /// Callback for scroll events: (deltaX, deltaY, phase, momentumPhase)
    var onScroll: ((CGFloat, CGFloat, MirageScrollPhase, MirageScrollPhase) -> Void)?

    /// Callback for rotation events: (rotationDegrees, phase)
    var onRotation: ((CGFloat, MirageScrollPhase) -> Void)?

    /// Size of scrollable area - large enough for extended scrolling before recenter
    private let scrollableSize: CGFloat = 100_000

    /// Whether we're currently tracking a scroll gesture (finger on trackpad)
    private var isTracking = false

    /// Last content offset for calculating deltas
    private var lastContentOffset: CGPoint = .zero

    /// Flag to suppress scroll events during recenter operation
    private var isRecentering = false

    /// Gesture recognizers for trackpad pinch/rotation
    private var rotationGesture: UIRotationGestureRecognizer!

    /// State tracking for incremental gesture deltas
    private var lastRotationAngle: CGFloat = 0.0

    override init(frame: CGRect) {
        scrollView = UIScrollView(frame: frame)
        scrollContent = UIView()
        contentView = UIView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        scrollView = UIScrollView()
        scrollContent = UIView()
        contentView = UIView()
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        // Ensure this view doesn't respect safe area insets
        insetsLayoutMarginsFromSafeArea = false

        // Configure scroll view for native physics
        scrollView.delegate = self
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.bounces = true
        scrollView.alwaysBounceVertical = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.decelerationRate = .normal
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // Make scroll view invisible but still receive events
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false

        // CRITICAL: Only accept trackpad/mouse wheel scrolling, not direct touch
        scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue),
        ]

        // Add scroll content (large enough to allow scrolling in all directions)
        scrollContent.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(scrollContent)

        // Content view holds the actual Metal view (stays pinned to our bounds)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contentView)

        // Add scroll view as overlay on top (receives trackpad events, passes through other input)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            // Scroll view fills our bounds
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            // Content view also fills bounds (stays stationary)
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Set scroll content size explicitly (UIScrollView needs this)
        scrollContent.frame = CGRect(x: 0, y: 0, width: scrollableSize, height: scrollableSize)
        scrollView.contentSize = CGSize(width: scrollableSize, height: scrollableSize)

        // Rotation gesture for trackpad (indirectPointer only)
        rotationGesture = UIRotationGestureRecognizer(target: self, action: #selector(handleRotation(_:)))
        rotationGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        rotationGesture.delegate = self
        addGestureRecognizer(rotationGesture)
    }

    override func layoutSubviews() {
        if !Thread.isMainThread {
            Task { @MainActor [weak self] in
                self?.setNeedsLayout()
            }
            return
        }
        super.layoutSubviews()

        // Center content offset on initial layout
        recenterIfNeeded(force: lastContentOffset == .zero)
    }

    /// Center the scroll view's content offset
    /// - Parameter force: If true, recenter even if currently scrolling
    private func recenterIfNeeded(force: Bool = false) {
        let centerOffset = CGPoint(
            x: (scrollableSize - bounds.width) / 2,
            y: (scrollableSize - bounds.height) / 2
        )

        // Only recenter if not currently scrolling (unless forced)
        if force || (!isTracking && !scrollView.isDecelerating) {
            // Suppress scroll events during recenter operation
            isRecentering = true
            scrollView.contentOffset = centerOffset
            lastContentOffset = centerOffset
            isRecentering = false
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        isTracking = true
        lastContentOffset = scrollView.contentOffset

        // Send scroll began phase
        onScroll?(0, 0, .began, .none)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Skip sending events during recenter operation
        guard !isRecentering else { return }

        let currentOffset = scrollView.contentOffset
        // Calculate deltas (inverted: content moving left = scrolling right)
        let deltaX = lastContentOffset.x - currentOffset.x
        let deltaY = lastContentOffset.y - currentOffset.y
        lastContentOffset = currentOffset

        // Determine phases based on tracking/decelerating state
        let phase: MirageScrollPhase = isTracking ? .changed : .none
        let momentumPhase: MirageScrollPhase = scrollView.isDecelerating ? .changed : .none

        // Send scroll delta if there's actual movement
        if deltaX != 0 || deltaY != 0 { onScroll?(deltaX, deltaY, phase, momentumPhase) }
    }

    func scrollViewDidEndDragging(_: UIScrollView, willDecelerate decelerate: Bool) {
        isTracking = false

        if !decelerate {
            // No momentum, end immediately and recenter
            onScroll?(0, 0, .ended, .none)
            recenterIfNeeded()
        }
    }

    func scrollViewDidEndDecelerating(_: UIScrollView) {
        // Momentum ended, send final event and recenter
        onScroll?(0, 0, .none, .ended)
        recenterIfNeeded()
    }

    func scrollViewDidEndScrollingAnimation(_: UIScrollView) {
        // Animation ended (e.g., from programmatic scroll)
        recenterIfNeeded()
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
        _: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
    )
    -> Bool {
        // Allow pinch + rotation simultaneously (map-style interaction)
        // Allow gestures to work alongside scroll view's pan
        true
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
}
#endif
