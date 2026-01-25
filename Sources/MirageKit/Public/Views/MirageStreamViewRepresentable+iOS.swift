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

    /// Callback when drawable metrics change - reports actual pixel dimensions and scale
    public var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?

    /// Callback when the view decides on a refresh rate override (60 or 120).
    public var onRefreshRateOverrideChange: ((Int) -> Void)?

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
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)? = nil,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        cursorStore: MirageClientCursorStore? = nil,
        onBecomeActive: (() -> Void)? = nil,
        dockSnapEnabled: Bool = false
    ) {
        self.streamID = streamID
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        self.cursorStore = cursorStore
        self.onBecomeActive = onBecomeActive
        self.dockSnapEnabled = dockSnapEnabled
    }

    public func makeCoordinator() -> MirageStreamViewCoordinator {
        MirageStreamViewCoordinator(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onBecomeActive: onBecomeActive
        )
    }

    public func makeUIView(context: Context) -> InputCapturingView {
        let view = InputCapturingView(frame: .zero)
        view.onInputEvent = context.coordinator.handleInputEvent
        view.onDrawableMetricsChanged = context.coordinator.handleDrawableMetricsChanged
        view.onRefreshRateOverrideChange = onRefreshRateOverrideChange
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
        context.coordinator.onDrawableMetricsChanged = onDrawableMetricsChanged
        context.coordinator.onBecomeActive = onBecomeActive

        // Update stream ID for direct frame cache access
        // CRITICAL: This allows Metal view to read frames without any Swift actor overhead
        uiView.streamID = streamID

        uiView.dockSnapEnabled = dockSnapEnabled
        uiView.cursorStore = cursorStore
        uiView.onDrawableMetricsChanged = context.coordinator.handleDrawableMetricsChanged
        uiView.onRefreshRateOverrideChange = onRefreshRateOverrideChange
    }
}
#endif
