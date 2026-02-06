//
//  SharedVirtualDisplayManager+Cleanup.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Shared virtual display manager extensions.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    // MARK: - Cleanup

    /// Destroy the shared display and clear all consumers
    /// Called during host shutdown
    func destroyAllAndClear() async {
        activeConsumers.removeAll()
        await destroyDisplay()
        MirageLogger.host("Destroyed shared display and cleared all consumers")
    }

    /// Get statistics about the shared display
    func getStatistics() -> (hasDisplay: Bool, consumerCount: Int, resolution: CGSize?) {
        (
            hasDisplay: sharedDisplay != nil,
            consumerCount: activeConsumers.count,
            resolution: sharedDisplay?.resolution
        )
    }
}
#endif
