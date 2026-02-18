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

    /// Cursor store for pointer updates.
    public var cursorStore: MirageClientCursorStore?

    /// Cursor position store for secondary display sync.
    public var cursorPositionStore: MirageClientCursorPositionStore?

    /// Whether the system cursor should be locked/hidden.
    public var cursorLockEnabled: Bool

    /// Optional cap for drawable pixel dimensions.
    public var maxDrawableSize: CGSize?

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        cursorPositionStore: MirageClientCursorPositionStore? = nil,
        cursorLockEnabled: Bool = false,
        maxDrawableSize: CGSize? = nil
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.cursorStore = cursorStore
        self.cursorPositionStore = cursorPositionStore
        self.cursorLockEnabled = cursorLockEnabled
        self.maxDrawableSize = maxDrawableSize
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged
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
        metalView.maxDrawableSize = maxDrawableSize
        metalView.streamID = streamID

        wrapper.cursorStore = cursorStore
        wrapper.cursorPositionStore = cursorPositionStore
        wrapper.cursorLockEnabled = cursorLockEnabled
        wrapper.streamID = streamID

        // Configure scroll callback for native trackpad physics
        wrapper
            .onScroll = { [weak coordinator = context.coordinator] deltaX, deltaY, location, phase, momentumPhase, isPrecise in
                let event = MirageScrollEvent(
                    deltaX: deltaX,
                    deltaY: deltaY,
                    location: location,
                    phase: phase,
                    momentumPhase: momentumPhase,
                    modifiers: [], // Modifiers tracked separately via flagsChanged
                    isPrecise: isPrecise
                )
                coordinator?.handleInputEvent(.scrollWheel(event))
            }

        // Configure mouse/keyboard event callback
        wrapper.onMouseEvent = { [weak coordinator = context.coordinator] event in
            coordinator?.handleInputEvent(event)
        }

        return wrapper
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onInputEvent = onInputEvent

        if let metalView = context.coordinator.metalView { metalView.streamID = streamID }
        if let metalView = context.coordinator.metalView { metalView.maxDrawableSize = maxDrawableSize }

        if let wrapper = nsView as? ScrollPhysicsCapturingNSView {
            wrapper.cursorStore = cursorStore
            wrapper.cursorPositionStore = cursorPositionStore
            wrapper.cursorLockEnabled = cursorLockEnabled
            wrapper.streamID = streamID
        }
    }
}
#endif
