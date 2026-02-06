import MirageKit
#if os(macOS)

//
//  UnlockManager+DisplayWake.swift
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
    // MARK: - Display Wake

    /// Wake the display without blocking
    func wakeDisplayNonBlocking() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/caffeinate")
        process.arguments = ["-u", "-t", "3"]
        try? process.run()

        if powerAssertionID == 0 {
            let assertionName = "MirageUnlock" as CFString
            let assertionType = kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString

            let result = IOPMAssertionCreateWithName(
                assertionType,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                assertionName,
                &powerAssertionID
            )

            if result == kIOReturnSuccess { MirageLogger.host("Created power assertion for unlock") }
        }
    }

    /// Release the power assertion
    func releaseDisplayAssertion() async {
        if powerAssertionID != 0 {
            IOPMAssertionRelease(powerAssertionID)
            powerAssertionID = 0
            MirageLogger.host("Released power assertion")
        }
    }
}

#endif
