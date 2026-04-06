//
//  MirageStreamViewRepresentable+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import MirageKit
#if os(macOS)
import SwiftUI

public struct MirageStreamViewRepresentable: NSViewRepresentable {
    public let streamID: StreamID

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable metrics change - reports pixel size and scale factor
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view's effective refresh rate changes (screen move or preference toggle).
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

    /// Cursor store for pointer updates.
    public var cursorStore: MirageClientCursorStore?

    /// Cursor position store for desktop cursor sync.
    public var cursorPositionStore: MirageClientCursorPositionStore?

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

    /// Whether locked desktop cursor input may move beyond the streamed view bounds.
    public var allowsExtendedDesktopCursorBounds: Bool

    /// Whether the stream can recapture cursor lock after a temporary local unlock.
    public var cursorLockCanRecapture: Bool

    /// Callback when the client should temporarily unlock cursor capture.
    public var onCursorLockEscapeRequested: (() -> Void)?

    /// Callback when the client should recapture cursor lock after a temporary unlock.
    public var onCursorLockRecaptureRequested: (() -> Void)?

    /// Whether Mirage should render its synthetic local cursor presentation.
    public var syntheticCursorEnabled: Bool

    /// Whether input capture should actively process mouse/keyboard events.
    public var inputEnabled: Bool

    /// Active vs passive presentation tier.
    public var presentationTier: StreamPresentationTier

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize?

    /// Client-reserved shortcuts that should not be forwarded to the host.
    public var clientShortcuts: [MirageClientShortcut]

    /// Callback when a client-reserved shortcut is triggered.
    public var onClientShortcut: ((MirageClientShortcut) -> Void)?

    /// Unified actions triggered by shortcuts, gestures, or the control bar.
    public var actions: [MirageAction]

    /// Callback when a unified action is triggered.
    public var onActionTriggered: ((MirageAction) -> Void)?

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? = nil,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        cursorPositionStore: MirageClientCursorPositionStore? = nil,
        cursorLockEnabled: Bool = false,
        allowsExtendedDesktopCursorBounds: Bool = false,
        cursorLockCanRecapture: Bool = false,
        onCursorLockEscapeRequested: (() -> Void)? = nil,
        onCursorLockRecaptureRequested: (() -> Void)? = nil,
        syntheticCursorEnabled: Bool = true,
        inputEnabled: Bool = true,
        presentationTier: StreamPresentationTier = .activeLive,
        maxDrawableSize: CGSize? = nil,
        clientShortcuts: [MirageClientShortcut] = [],
        onClientShortcut: ((MirageClientShortcut) -> Void)? = nil,
        actions: [MirageAction] = [],
        onActionTriggered: ((MirageAction) -> Void)? = nil
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        self.cursorStore = cursorStore
        self.cursorPositionStore = cursorPositionStore
        self.cursorLockEnabled = cursorLockEnabled
        self.allowsExtendedDesktopCursorBounds = allowsExtendedDesktopCursorBounds
        self.cursorLockCanRecapture = cursorLockCanRecapture
        self.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        self.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        self.syntheticCursorEnabled = syntheticCursorEnabled
        self.inputEnabled = inputEnabled
        self.presentationTier = presentationTier
        self.maxDrawableSize = maxDrawableSize
        self.clientShortcuts = clientShortcuts
        self.onClientShortcut = onClientShortcut
        self.actions = actions
        self.onActionTriggered = onActionTriggered
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange
        )
    }

    public func makeNSView(context: Context) -> NSView {
        let wrapper = ScrollPhysicsCapturingNSView(frame: .zero)

        // Create Metal view and add to wrapper's content view
        let metalView = MirageMetalView(frame: .zero, device: nil)
        metalView.translatesAutoresizingMaskIntoConstraints = false
        wrapper.contentView.addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: wrapper.contentView.topAnchor),
            metalView.leadingAnchor.constraint(equalTo: wrapper.contentView.leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: wrapper.contentView.trailingAnchor),
            metalView.bottomAnchor.constraint(equalTo: wrapper.contentView.bottomAnchor),
        ])

        // Store Metal view reference in coordinator
        context.coordinator.metalView = metalView
        metalView.onDrawableMetricsChanged = context.coordinator.handleDrawableMetricsChanged
        metalView.onRefreshRateOverrideChange = context.coordinator.handleRefreshRateOverrideChange
        metalView.maxDrawableSize = maxDrawableSize
        metalView.streamPresentationTier = presentationTier
        metalView.streamID = streamID

        wrapper.cursorStore = cursorStore
        wrapper.cursorPositionStore = cursorPositionStore
        wrapper.allowsExtendedCursorBounds = allowsExtendedDesktopCursorBounds
        wrapper.cursorLockEnabled = cursorLockEnabled
        wrapper.canRecaptureCursorLock = cursorLockCanRecapture
        wrapper.onCursorLockEscapeRequested = onCursorLockEscapeRequested
        wrapper.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
        wrapper.syntheticCursorEnabled = syntheticCursorEnabled
        wrapper.inputEnabled = inputEnabled
        wrapper.streamID = streamID

        // Configure scroll callback for native trackpad physics
        wrapper
            .onScroll = { [weak coordinator = context.coordinator] deltaX, deltaY, location, phase, momentumPhase, modifiers, isPrecise in
                let event = MirageScrollEvent(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    location: location,
                    phase: phase,
                    momentumPhase: momentumPhase,
                    modifiers: modifiers,
                    isPrecise: isPrecise
                )
                coordinator?.handleInputEvent(.scrollWheel(event))
            }

        // Configure mouse/keyboard event callback
        wrapper.onMouseEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.handleInputEvent(event)
        }

        // Configure client shortcut passthrough
        wrapper.clientShortcuts = clientShortcuts
        wrapper.onClientShortcut = onClientShortcut
        wrapper.actions = actions
        wrapper.onActionTriggered = onActionTriggered

        return wrapper
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onRefreshRateOverrideChange = onRefreshRateOverrideChange

        if let metalView = context.coordinator.metalView { metalView.streamID = streamID }
        if let metalView = context.coordinator.metalView { metalView.maxDrawableSize = maxDrawableSize }
        if let metalView = context.coordinator.metalView { metalView.streamPresentationTier = presentationTier }

        if let wrapper = nsView as? ScrollPhysicsCapturingNSView {
            wrapper.cursorStore = cursorStore
            wrapper.cursorPositionStore = cursorPositionStore
            wrapper.allowsExtendedCursorBounds = allowsExtendedDesktopCursorBounds
            wrapper.cursorLockEnabled = cursorLockEnabled
            wrapper.canRecaptureCursorLock = cursorLockCanRecapture
            wrapper.onCursorLockEscapeRequested = onCursorLockEscapeRequested
            wrapper.onCursorLockRecaptureRequested = onCursorLockRecaptureRequested
            wrapper.syntheticCursorEnabled = syntheticCursorEnabled
            wrapper.inputEnabled = inputEnabled
            wrapper.streamID = streamID
            wrapper.clientShortcuts = clientShortcuts
            wrapper.onClientShortcut = onClientShortcut
        }
    }
}
#endif
