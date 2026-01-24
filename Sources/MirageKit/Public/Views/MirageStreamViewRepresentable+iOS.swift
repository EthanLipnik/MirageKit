//
//  MirageStreamViewRepresentable+iOS.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

#if os(iOS) || os(visionOS)
import SwiftUI

// MARK: - SwiftUI Representable (iOS)

public struct MirageStreamViewRepresentable: UIViewRepresentable {
    public let streamID: StreamID

    /// Callback for sending input events to the host
    public var onInputEvent: ((MirageInputEvent) -> Void)?

    /// Callback when drawable size changes - reports actual pixel dimensions
    public var onDrawableSizeChanged: ((CGSize) -> Void)?

    /// Cursor store for pointer updates (decoupled from SwiftUI observation).
    public var cursorStore: MirageClientCursorStore?

    /// Callback when app becomes active (returns from background).
    /// Used to trigger stream recovery after app switching.
    public var onBecomeActive: (() -> Void)?

    /// Whether input should snap to the dock edge.
    public var dockSnapEnabled: Bool

    public init(
        streamID: StreamID,
        onInputEvent: ((MirageInputEvent) -> Void)? = nil,
        onDrawableSizeChanged: ((CGSize) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        onBecomeActive: (() -> Void)? = nil,
        dockSnapEnabled: Bool = false
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChanged = onDrawableSizeChanged
        self.cursorStore = cursorStore
        self.onBecomeActive = onBecomeActive
        self.dockSnapEnabled = dockSnapEnabled
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableSizeChanged: onDrawableSizeChanged,
            onBecomeActive: onBecomeActive
        )
    }

    public func makeUIView(context: Context) -> InputCapturingView {
        let view = InputCapturingView(frame: .zero)
        view.onInputEvent = context.coordinator.handleInputEvent
        view.onDrawableSizeChanged = context.coordinator.handleDrawableSizeChanged
        view.onBecomeActive = context.coordinator.handleBecomeActive
        view.dockSnapEnabled = dockSnapEnabled
        view.cursorStore = cursorStore
        // Set stream ID for direct frame cache access (bypasses all actor machinery)
        view.streamID = streamID
        return view
    }

    public func updateUIView(_ uiView: InputCapturingView, context: Context) {
        // Update coordinator's callbacks in case they changed
        context.coordinator.onInputEvent = onInputEvent
        context.coordinator.onDrawableSizeChanged = onDrawableSizeChanged
        context.coordinator.onBecomeActive = onBecomeActive

        // Update stream ID for direct frame cache access
        // CRITICAL: This allows Metal view to read frames without any Swift actor overhead
        uiView.streamID = streamID

        uiView.dockSnapEnabled = dockSnapEnabled
        uiView.cursorStore = cursorStore
    }
}
#endif
