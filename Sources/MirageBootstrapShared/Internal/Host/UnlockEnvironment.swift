//
//  UnlockEnvironment.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import CoreGraphics
import Foundation

#if os(macOS)

package struct UnlockEnvironment {
    package let displayBoundsProvider: @Sendable () async -> CGRect
    package let prepareForCredentialEntry: @Sendable () async -> Void
    package let cleanupAfterCredentialEntry: @Sendable () async -> Void
    package let postHIDEvent: @Sendable (CGEvent) -> Void

    package init(
        displayBoundsProvider: @escaping @Sendable () async -> CGRect = { CGDisplayBounds(CGMainDisplayID()) },
        prepareForCredentialEntry: @escaping @Sendable () async -> Void = {},
        cleanupAfterCredentialEntry: @escaping @Sendable () async -> Void = {},
        postHIDEvent: @escaping @Sendable (CGEvent) -> Void = { event in
            event.post(tap: .cghidEventTap)
        }
    ) {
        self.displayBoundsProvider = displayBoundsProvider
        self.prepareForCredentialEntry = prepareForCredentialEntry
        self.cleanupAfterCredentialEntry = cleanupAfterCredentialEntry
        self.postHIDEvent = postHIDEvent
    }
}

#endif
