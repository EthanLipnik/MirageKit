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

    /// Destroy all managed displays and clear all consumers
    /// Called during host shutdown
    func destroyAllAndClear() async {
        let dedicatedDisplays = Array(dedicatedDisplaysByStreamID.values)
        dedicatedDisplaysByStreamID.removeAll()
        activeConsumers.removeAll()
        for display in dedicatedDisplays {
            await destroyDisplay(display)
        }
        await destroyDisplay()
        MirageLogger.host(
            "Destroyed shared display, \(dedicatedDisplays.count) dedicated displays, and cleared all consumers"
        )
    }

    /// Get statistics about shared and dedicated displays.
    func getStatistics() -> (
        hasDisplay: Bool,
        consumerCount: Int,
        resolution: CGSize?,
        dedicatedDisplayCount: Int
    ) {
        (
            hasDisplay: sharedDisplay != nil,
            consumerCount: activeConsumers.count,
            resolution: sharedDisplay?.resolution,
            dedicatedDisplayCount: dedicatedDisplaysByStreamID.count
        )
    }
}
#endif
