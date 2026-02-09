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
    var onBecomeActive: (() -> Void)?
    weak var metalView: MirageMetalView?

    init(
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableMetricsChanged: ((MirageDrawableMetrics) -> Void)?,
        onBecomeActive: (() -> Void)? = nil
    ) {
        self.onInputEvent = onInputEvent
        self.onDrawableMetricsChanged = onDrawableMetricsChanged
        self.onBecomeActive = onBecomeActive
    }

    func handleInputEvent(_ event: MirageInputEvent) {
        onInputEvent?(event)
    }

    func handleDrawableMetricsChanged(_ metrics: MirageDrawableMetrics) {
        let callback = UnsafeDrawableMetricsCallback(callback: onDrawableMetricsChanged)
        Task { @MainActor in
            await Task.yield()
            callback.callback?(metrics)
        }
    }

    func handleBecomeActive() {
        onBecomeActive?()
    }
}

private struct UnsafeDrawableMetricsCallback: @unchecked Sendable {
    let callback: ((MirageDrawableMetrics) -> Void)?
}
