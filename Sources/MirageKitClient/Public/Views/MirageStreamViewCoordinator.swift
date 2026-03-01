//
//  MirageStreamViewCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import Foundation
import MirageKit

public final class MirageStreamViewCoordinator {
    var onInputEvent: ((MirageInputEvent) -> Void)?
    var onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?
    var onRefreshRateOverrideChange: ((Int) -> Void)?
    var onBecomeActive: (() -> Void)?
    var onHardwareKeyboardPresenceChanged: ((Bool) -> Void)?
    var onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)?
    var onDirectTouchActivity: (() -> Void)?
    var onDictationStateChanged: ((Bool) -> Void)?
    var onDictationError: ((String) -> Void)?
    weak var metalView: MirageMetalView?
    private var representableUpdateCount: UInt64 = 0
    private var representableUpdateLogStreamID: StreamID?
    private var lastRepresentableUpdateLogTime: CFAbsoluteTime = 0
    private let representableUpdateLogInterval: CFTimeInterval = 5.0

    init(
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onRefreshRateOverrideChange: ((Int) -> Void)? = nil,
        onBecomeActive: (() -> Void)? = nil,
        onHardwareKeyboardPresenceChanged: ((Bool) -> Void)? = nil,
        onSoftwareKeyboardVisibilityChanged: ((Bool) -> Void)? = nil,
        onDirectTouchActivity: (() -> Void)? = nil,
        onDictationStateChanged: ((Bool) -> Void)? = nil,
        onDictationError: ((String) -> Void)? = nil
    ) {
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onRefreshRateOverrideChange = onRefreshRateOverrideChange
        self.onBecomeActive = onBecomeActive
        self.onHardwareKeyboardPresenceChanged = onHardwareKeyboardPresenceChanged
        self.onSoftwareKeyboardVisibilityChanged = onSoftwareKeyboardVisibilityChanged
        self.onDirectTouchActivity = onDirectTouchActivity
        self.onDictationStateChanged = onDictationStateChanged
        self.onDictationError = onDictationError
    }

    func handleInputEvent(_ event: MirageInputEvent) {
        onInputEvent?(event)
    }

    func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        onDrawableMetricsChanged?(metrics)
    }

    func handleRefreshRateOverrideChange(_ override: Int) {
        onRefreshRateOverrideChange?(override)
    }

    func handleBecomeActive() {
        onBecomeActive?()
    }

    func handleHardwareKeyboardPresenceChanged(_ isPresent: Bool) {
        onHardwareKeyboardPresenceChanged?(isPresent)
    }

    func handleSoftwareKeyboardVisibilityChanged(_ isVisible: Bool) {
        onSoftwareKeyboardVisibilityChanged?(isVisible)
    }

    func handleDirectTouchActivity() {
        onDirectTouchActivity?()
    }

    func handleDictationStateChanged(_ isActive: Bool) {
        onDictationStateChanged?(isActive)
    }

    func handleDictationError(_ message: String) {
        onDictationError?(message)
    }

    func noteRepresentableUpdate(for streamID: StreamID) {
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
        guard now - lastRepresentableUpdateLogTime >= representableUpdateLogInterval else {
            return
        }

        let updates = representableUpdateCount
        representableUpdateCount = 0
        lastRepresentableUpdateLogTime = now
        MirageLogger.client(
            "Stream view representable updates: stream=\(streamID), updates=\(updates), windowSeconds=5"
        )
    }
}
