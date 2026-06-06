//
//  MirageStreamViewCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
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
import CoreGraphics
import Foundation

/// Bridges platform stream views to Mirage input, metrics, and keyboard callbacks.
public final class MirageStreamViewCoordinator {
    #if os(iOS) || os(visionOS)
    /// Minimum interval between repeated representable update diagnostics.
    private static let representableUpdateLogInterval: CFTimeInterval = 5.0
    #endif

    var onInputEvent: ((MirageInput.MirageInputEvent) -> Void)?
    var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    var onContainerSizeChanged: ((CGSize) -> Void)?
    var onRefreshRateOverrideChange: ((Int) -> Void)?
    #if os(iOS) || os(visionOS)
    var onBecomeActive: (() -> Void)?
    var onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    var onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    var onDirectTouchActivity: (() -> Void)?
    var onDictationStateChanged: ((Bool) -> Void)?
    var onDictationError: ((String) -> Void)?
    var onDictationInputLevelChanged: ((Float) -> Void)?
    var onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)?
    #endif
    weak var sampleBufferView: MirageSampleBufferView?
    #if os(iOS) || os(visionOS)
    private var representableUpdateCount: UInt64 = 0
    private var representableUpdateLogStreamID: StreamID?
    private var lastRepresentableUpdateLogTime: CFAbsoluteTime = 0
    #endif

    init(
        onInputEvent: ((MirageInput.MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onContainerSizeChanged: ((CGSize) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil
    ) {
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onContainerSizeChanged = onContainerSizeChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
    }

    #if os(iOS) || os(visionOS)
    convenience init(
        onInputEvent: ((MirageInput.MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onContainerSizeChanged: ((CGSize) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        onBecomeActive: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil,
        onDictationInputLevelChanged: ((Float) -> Void)? = nil,
        onResolvedPointerLockStateChanged: ((MirageResolvedPointerLockState) -> Void)? = nil
    ) {
        self.init(
            onInputEvent: onInputEvent,
            onDrawableMetricsChanged: onDrawableMetricsChanged,
            onContainerSizeChanged: onContainerSizeChanged,
            onRefreshRateOverrideChange: onRefreshRateOverrideChange
        )
        self.onBecomeActive = onBecomeActive
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.onDirectTouchActivity = onDirectTouchActivity
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
        self.onDictationInputLevelChanged = onDictationInputLevelChanged
        self.onResolvedPointerLockStateChanged = onResolvedPointerLockStateChanged
    }
    #endif

    #if os(iOS) || os(visionOS)
    func noteRepresentableUpdate(for streamID: StreamID) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        if representableUpdateLogStreamID != streamID {
            representableUpdateLogStreamID = streamID
            representableUpdateCount = 0
            lastRepresentableUpdateLogTime = 0
        }

        representableUpdateCount &+= 1
        let now = CFAbsoluteTimeGetCurrent()
        if lastRepresentableUpdateLogTime == 0 {
            lastRepresentableUpdateLogTime = now
            return
        }
        guard now - lastRepresentableUpdateLogTime >= Self.representableUpdateLogInterval else {
            return
        }

        let updates = representableUpdateCount
        representableUpdateCount = 0
        lastRepresentableUpdateLogTime = now
        MirageLogger.metrics(
            "Stream view representable updates: stream=\(streamID), updates=\(updates), windowSeconds=5"
        )
    }
    #endif
}
