//
//  PowerAssertionManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/8/26.
//

import Foundation

#if os(macOS)
import IOKit
import IOKit.pwr_mgt

/// Manages IOKit power assertions to prevent the Mac from sleeping or locking during streaming.
///
/// Power assertions tell the system that important activity is occurring and the system
/// should not idle-sleep or turn off the display. This is essential for a streaming host
/// where the display content must remain available even without local user interaction.
actor PowerAssertionManager {
    /// Singleton instance
    static let shared = PowerAssertionManager()

    /// The active power assertion ID (0 = no assertion)
    private var assertionID: IOPMAssertionID = 0

    /// Whether an assertion is currently active
    private var isAssertionActive: Bool {
        assertionID != 0
    }

    /// Reference count for nested enable/disable calls
    private var referenceCount: Int = 0

    private init() {}

    // MARK: - Public API

    /// Enable power assertion to prevent display sleep.
    /// Call this when streaming starts. Uses reference counting so multiple callers
    /// can safely call enable/disable independently.
    func enable() {
        referenceCount += 1

        guard referenceCount == 1 else {
            MirageLogger.log(.host, "PowerAssertion: incremented reference count to \(referenceCount)")
            return
        }

        createAssertion()
    }

    /// Disable power assertion.
    /// Call this when streaming stops. The assertion is only released when
    /// all callers have called disable (reference count reaches 0).
    func disable() {
        guard referenceCount > 0 else {
            MirageLogger.log(.host, "PowerAssertion: disable called but reference count already 0")
            return
        }

        referenceCount -= 1

        guard referenceCount == 0 else {
            MirageLogger.log(.host, "PowerAssertion: decremented reference count to \(referenceCount)")
            return
        }

        releaseAssertion()
    }

    /// Force release all assertions regardless of reference count.
    /// Use this for cleanup during app termination.
    func forceDisable() {
        referenceCount = 0
        releaseAssertion()
    }

    // MARK: - Private Implementation

    private func createAssertion() {
        guard !isAssertionActive else {
            MirageLogger.log(.host, "PowerAssertion: already active")
            return
        }

        // Create assertion to prevent display sleep
        // This keeps the display on and prevents the system from idle-sleeping
        let reason = "Mirage is streaming windows to connected clients" as CFString

        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &assertionID
        )

        if result == kIOReturnSuccess {
            MirageLogger.log(.host, "PowerAssertion: created (ID: \(assertionID)) - display sleep prevented")
        } else {
            MirageLogger.error(.host, "PowerAssertion: failed to create, error: \(result)")
            assertionID = 0
        }
    }

    private func releaseAssertion() {
        guard isAssertionActive else {
            MirageLogger.log(.host, "PowerAssertion: no active assertion to release")
            return
        }

        let result = IOPMAssertionRelease(assertionID)

        if result == kIOReturnSuccess {
            MirageLogger.log(.host, "PowerAssertion: released (ID: \(assertionID)) - display sleep allowed")
        } else {
            MirageLogger.error(.host, "PowerAssertion: failed to release, error: \(result)")
        }

        assertionID = 0
    }
}

#endif
