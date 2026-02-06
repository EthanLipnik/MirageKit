//
//  SharedVirtualDisplayManager+Maintenance.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Shared virtual display maintenance helpers.
//

import MirageKit
#if os(macOS)
import CoreGraphics
import Foundation

extension SharedVirtualDisplayManager {
    func resetVirtualDisplayIdentity() async throws {
        guard activeConsumers.isEmpty else {
            throw SharedDisplayError.creationFailed("Active streams are using the virtual display")
        }

        let displayID = sharedDisplay?.displayID
        await destroyDisplay()
        CGVirtualDisplayBridge.invalidateAllPersistentSerials()

        if let displayID {
            MirageLogger.host("Reset virtual display identity for display \(displayID)")
        } else {
            MirageLogger.host("Reset virtual display identity")
        }
    }
}
#endif
