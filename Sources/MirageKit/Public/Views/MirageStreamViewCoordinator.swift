//
//  MirageStreamViewCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/23/26.
//

import CoreGraphics
import Foundation

public final class MirageStreamViewCoordinator {
    var onInputEvent: ((MirageInputEvent) -> Void)?
    var onDrawableSizeChanged: ((CGSize) -> Void)?
    var onBecomeActive: (() -> Void)?
    weak var metalView: MirageMetalView?

    init(
        onInputEvent: ((MirageInputEvent) -> Void)?,
        onDrawableSizeChanged: ((CGSize) -> Void)?,
        onBecomeActive: (() -> Void)? = nil
    ) {
        self.onInputEvent = onInputEvent
        self.onDrawableSizeChanged = onDrawableSizeChanged
        self.onBecomeActive = onBecomeActive
    }

    func handleInputEvent(_ event: MirageInputEvent) {
        onInputEvent?(event)
    }

    func handleDrawableSizeChanged(_ size: CGSize) {
        onDrawableSizeChanged?(size)
    }

    func handleBecomeActive() {
        onBecomeActive?()
    }
}
