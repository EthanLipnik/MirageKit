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
        onDrawableMetricsChanged?(metrics)
    }

    func handleBecomeActive() {
        onBecomeActive?()
    }
}
