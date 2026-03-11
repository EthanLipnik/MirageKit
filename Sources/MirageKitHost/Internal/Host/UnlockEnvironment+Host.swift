//
//  UnlockEnvironment+Host.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

import CoreGraphics
import MirageBootstrapShared

#if os(macOS)

extension UnlockEnvironment {
    static let hostService: UnlockEnvironment = .init(
        displayBoundsProvider: {
            if let sharedBounds = await SharedVirtualDisplayManager.shared.getDisplayBounds() {
                return sharedBounds
            }
            return CGDisplayBounds(CGMainDisplayID())
        },
        prepareForCredentialEntry: {
            do {
                let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(.unlockKeyboard)
                MirageLogger.host("Using shared virtual display \(context.displayID) for unlock")
                try? await Task.sleep(for: .milliseconds(300))
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to acquire shared virtual display for unlock: ")
            }
        },
        cleanupAfterCredentialEntry: {
            await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.unlockKeyboard)
            MirageLogger.host("Released shared virtual display for unlock")
        },
        postHIDEvent: { event in
            MirageInjectedEventTag.postHID(event)
        }
    )
}

#endif
