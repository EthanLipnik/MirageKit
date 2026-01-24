//
//  MirageStreamViewRepresentable+macOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(macOS)
import SwiftUI

public struct MirageStreamViewRepresentable: NSViewRepresentable {
    public let streamID: StreamID

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableSizeChanged: ((CGSize) -> Void)? = nil
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChanged = onDrawableSizeChanged
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(onInputEvent: onInputEvent, onDrawableSizeChanged: onDrawableSizeChanged)
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
            metalView.bottomAnchor.constraint(equalTo: wrapper.contentView.bottomAnchor)
        ])

        // Store Metal view reference in coordinator
        context.coordinator.metalView = metalView
        metalView.onDrawableSizeChanged = context.coordinator.handleDrawableSizeChanged
        metalView.streamID = streamID

        // Configure scroll callback for native trackpad physics
        wrapper.onScroll = { [weak coordinator = context.coordinator] deltaX, deltaY, location, phase, momentumPhase, isPrecise in
            let event = MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: location,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: [],  // Modifiers tracked separately via flagsChanged
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
        context.coordinator.onDrawableSizeChanged = onDrawableSizeChanged
        context.coordinator.onInputEvent = onInputEvent

        if let metalView = context.coordinator.metalView {
            metalView.streamID = streamID
        }
    }
}
#endif
