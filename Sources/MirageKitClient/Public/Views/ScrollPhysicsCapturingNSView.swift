//
//  ScrollPhysicsCapturingNSView.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(macOS)
import AppKit
import QuartzCore

/// Invisible scroll view that captures native trackpad scroll physics on macOS.
/// The actual content view stays pinned while scroll events are forwarded
/// to the host with native momentum and bounce physics.
final class ScrollPhysicsCapturingNSView: NSView {
    /// Poll interval for observing modifier-state changes outside key events.
    static let modifierPollInterval: TimeInterval = 0.1

    /// Minimum interval between non-forced locked-cursor view refreshes.
    static let lockedCursorRefreshInterval: CFTimeInterval = MirageInteractionCadence.frameInterval120Seconds

    /// Duration after local cursor input during which host cursor updates are ignored.
    static let cursorLocalHoldInterval: CFTimeInterval = 0.12

    /// Per-frame interpolation factor for locked cursor smoothing.
    static let lockedCursorLerpAlpha: CGFloat = 0.25

    /// Normalized distance that snaps the locked cursor directly to the host target.
    static let lockedCursorSnapThreshold: CGFloat = 0.08

    /// Normalized distance below which locked cursor smoothing stops.
    static let lockedCursorStopThreshold: CGFloat = 0.002

    struct CursorSystemHooks {
        var mouseLocation: () -> CGPoint = { NSEvent.mouseLocation }
        var setAssociationEnabled: (Bool) -> Void = { isEnabled in
            CGAssociateMouseAndMouseCursorPosition(isEnabled ? 1 : 0)
        }

        var warpCursor: (CGPoint) -> Void = { point in
            CGWarpMouseCursorPosition(point)
        }

        var setCursor: (NSCursor) -> Void = { $0.set() }
        var hideCursor: () -> Void = { NSCursor.hide() }
        var unhideCursor: () -> Void = { NSCursor.unhide() }
    }

    nonisolated(unsafe) static var cursorSystemHooks = CursorSystemHooks()

    nonisolated static func globalDisplayFrameMaxY() -> CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.height ?? 1080
    }

    nonisolated static func globalDisplayCursorPosition(
        fromCocoaScreenPosition position: CGPoint,
        globalFrameMaxY: CGFloat
    )
    -> CGPoint {
        CGPoint(
            x: position.x,
            y: globalFrameMaxY - position.y
        )
    }

    /// Stream ID for cursor update routing
    var streamID: StreamID? {
        didSet {
            let previousID = registeredCursorStreamID
            if let previousID, previousID != streamID { MirageCursorUpdateRouter.shared.unregister(streamID: previousID) }
            registeredCursorStreamID = streamID
            if let streamID { MirageCursorUpdateRouter.shared.register(view: self, for: streamID) }
            refreshCursorUpdates(force: true)
        }
    }

    /// Cursor store for visibility updates
    var cursorStore: MirageClientCursorStore? {
        didSet {
            refreshCursorUpdates(force: true)
        }
    }

    /// Cursor position store for desktop cursor sync.
    var cursorPositionStore: MirageClientCursorPositionStore? {
        didSet {
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether the local system cursor should be hidden while streaming.
    var hideSystemCursor: Bool = false {
        didSet {
            guard hideSystemCursor != oldValue else { return }
            updateSystemCursorVisibility()
            updateLockedCursorViewVisibility()
            updateLockedCursorViewPosition()
            invalidateHostCursorRects()
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether the system cursor should be locked/hidden
    var cursorLockEnabled: Bool = false {
        didSet {
            guard cursorLockEnabled != oldValue else { return }
            updateCursorLockMode()
            refreshCursorUpdates(force: true)
        }
    }

    /// Host display dimensions in points for 1:1 cursor delta normalization.
    /// When set, locked-cursor deltas are normalized by these dimensions instead
    /// of the local view bounds, giving native macOS cursor feel regardless of
    /// the client window size.
    var hostDisplayPointSize: CGSize?

    /// Reference stream size for desktop aspect-fit presentation on macOS.
    var desktopPresentationReferenceSize: CGSize? {
        didSet {
            guard desktopPresentationReferenceSize != oldValue else { return }
            needsLayout = true
            invalidateHostCursorRects()
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
        }
    }

    /// Bounds source reported to window-driven stream resize logic.
    var containerSizingMode: MirageStreamContainerSizingMode = .contentLayout {
        didSet {
            guard containerSizingMode != oldValue else { return }
            reportContainerSizeIfChanged(force: true)
        }
    }

    /// Whether locked desktop cursor input may move beyond the streamed view bounds.
    var allowsExtendedCursorBounds: Bool = false {
        didSet {
            guard allowsExtendedCursorBounds != oldValue else { return }
            lockedCursorPosition = resolvedLockedCursorEventPosition(lockedCursorPosition)
            lockedCursorTargetPosition = resolvedLockedCursorEventPosition(lockedCursorTargetPosition)
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
        }
    }

    /// Whether cursor lock can be recaptured after a temporary local unlock.
    var canRecaptureCursorLock: Bool = false

    /// Callback when unmodified Escape should temporarily unlock cursor capture.
    var onCursorLockEscapeRequested: (() -> Void)?

    /// Callback when the next click should recapture cursor capture.
    var onCursorLockRecaptureRequested: (() -> Void)?

    /// Whether Mirage should render its synthetic locked-cursor overlay.
    var syntheticCursorEnabled: Bool = true {
        didSet {
            guard syntheticCursorEnabled != oldValue else { return }
            updateLockedCursorViewVisibility()
            updateLockedCursorViewPosition()
            refreshCursorUpdates(force: true)
            applyMirroredSystemCursorAppearance()
        }
    }

    /// Whether event handling is enabled for this capture view.
    var inputEnabled: Bool = true {
        didSet {
            guard inputEnabled != oldValue else { return }
            handleInputActivityStateChange()
        }
    }

    /// Whether macOS Input Monitoring backed shortcut forwarding is enabled.
    var shortcutForwardingEnabled: Bool = true {
        didSet {
            guard shortcutForwardingEnabled != oldValue else { return }
            handleInputActivityStateChange()
        }
    }

    /// The actual content we display (stays pinned to bounds)
    let contentView: NSView

    /// Callback for scroll events: (deltaX, deltaY, location, phase, momentumPhase, modifiers, isPrecise)
    /// Location is normalized in stream space and may exceed 0...1 for secondary desktop travel.
    var onScroll: ((CGFloat, CGFloat, CGPoint?, MirageScrollPhase, MirageScrollPhase, MirageModifierFlags, Bool) -> Void)?

    /// Callback for mouse events - used for forwarding clicks to host
    var onMouseEvent: ((MirageInputEvent) -> Void)?

    /// Callback when the platform container/window bounds change.
    var onContainerSizeChanged: ((CGSize) -> Void)? {
        didSet {
            if onContainerSizeChanged != nil {
                reportContainerSizeIfChanged(force: true)
            }
        }
    }

    /// Client-reserved shortcuts that should NOT be forwarded to the host.
    /// All other key equivalents are intercepted and forwarded.
    var clientShortcuts: [MirageClientShortcut] = []

    /// Callback for client-reserved shortcut actions (e.g. exit stream).
    var onClientShortcut: ((MirageClientShortcut) -> Void)?

    /// Unified actions that can be triggered by shortcuts.
    var actions: [MirageAction] = []

    /// Callback when a unified action is triggered.
    var onActionTriggered: ((MirageAction) -> Void)?

    /// Track current modifier state
    var currentModifiers: MirageModifierFlags = []
    var modifierPollTimer: Timer?

    /// Last known mouse location in stream space for scroll events.
    /// Secondary desktop cursor-lock travel may temporarily exceed `0...1`.
    var lastMouseLocation: CGPoint?

    /// Locked cursor view for secondary display mode
    let lockedCursorView = NSImageView(frame: .zero)
    var lastReportedContainerSize: CGSize = .zero
    var lockedCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorTargetPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var lockedCursorConfirmedHostPosition: CGPoint?
    var lockedCursorVisible: Bool = false
    var lockedCursorTargetVisible: Bool = false
    var lockedCursorSequence: UInt64 = 0
    var lastLockedCursorRefreshTime: CFTimeInterval = 0
    var lastCursorLocalInputTime: CFTimeInterval = 0
    var lockedCursorSmoothingTimer: Timer?
    var mirroredSystemCursorPosition: CGPoint = .init(x: 0.5, y: 0.5)
    var mirroredSystemCursorVisible: Bool = true
    var mirroredSystemCursorType: MirageCursorType = .arrow
    var mirroredSystemCursorPositionSequence: UInt64 = 0
    var mirroredSystemCursorTypeSequence: UInt64 = 0
    var cursorLockAnchor: CGPoint = .zero
    var cursorLockRestorePosition: CGPoint?
    var cursorHidden: Bool = false
    var cursorHiddenForTyping: Bool = false
    var suppressEscapeKeyUpForCursorUnlock = false
    let shortcutForwardingEventTap = MacShortcutForwardingEventTap()
    nonisolated(unsafe) var registeredCursorStreamID: StreamID?

    override init(frame: CGRect) {
        contentView = NSView(frame: frame)
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        contentView = NSView()
        super.init(coder: coder)
        setup()
    }

    deinit {
        MainActor.assumeIsolated {
            stopModifierPolling()
        }
        if let registeredCursorStreamID { MirageCursorUpdateRouter.shared.unregister(streamID: registeredCursorStreamID) }
        MainActor.assumeIsolated {
            cursorHiddenForTyping = false
            stopLockedCursorSmoothing()
        }
        MainActor.assumeIsolated {
            restoreCursorLockIfNeeded()
        }
    }
}

extension ScrollPhysicsCapturingNSView: MirageCursorUpdateHandling {}
#endif
