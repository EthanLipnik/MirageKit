import MirageKit
#if os(macOS)

//
//  UnlockManager+VirtualDisplay.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Unlock manager extensions.
//

import AppKit
import CoreGraphics
import Foundation

extension UnlockManager {
    // MARK: - Virtual Display Management

    /// Ensure virtual display exists for keyboard input on headless Macs
    /// Uses the shared virtual display manager for consistent resolution
    /// Also waits for loginwindow to render on the display before returning
    func ensureVirtualDisplay() async {
        do {
            let context = try await SharedVirtualDisplayManager.shared.acquireDisplayForConsumer(.unlockKeyboard)
            MirageLogger.host("Using shared virtual display \(context.displayID) for unlock")

            // Wait for display to be ready (basic display initialization)
            try? await Task.sleep(for: .milliseconds(300))

            // Wait for loginwindow to actually render on the display
            // This is critical on headless Macs - without this, HID events get queued
            // and delivered later when another display (like Jump Desktop) connects
            let loginWindowReady = await waitForLoginWindowReady(timeout: 8.0)
            if !loginWindowReady {
                MirageLogger.error(
                    .host,
                    "Proceeding with unlock despite loginwindow not being detected - HID events may be queued"
                )
            }
        } catch {
            MirageLogger.error(.host, "Failed to acquire shared virtual display for unlock: \(error)")
        }
    }

    /// Release virtual display
    func releaseVirtualDisplay() async {
        await SharedVirtualDisplayManager.shared.releaseDisplayForConsumer(.unlockKeyboard)
        MirageLogger.host("Released shared virtual display for unlock")
    }
}

#endif
