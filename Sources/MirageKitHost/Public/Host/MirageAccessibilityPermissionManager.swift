//
//  MirageAccessibilityPermissionManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

import MirageKit
#if os(macOS)
@preconcurrency import ApplicationServices
import Foundation
import Observation

/// Tracks macOS Accessibility permission state for host input injection UI.
@Observable
@MainActor
public final class MirageAccessibilityPermissionManager {
    /// Current cached permission state.
    public private(set) var isAccessibilityGranted = false

    /// Whether the system prompt has been requested in this process.
    private var hasPromptedThisSession = false

    /// Creates a permission manager and loads the current Accessibility permission state.
    public init() {
        refreshPermissionState()
    }

    /// Refreshes cached permission state without showing the system prompt.
    public func refreshPermissionState() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    /// Returns whether Accessibility is granted, optionally requesting the system prompt once.
    public func checkAndPromptIfNeeded(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() {
            isAccessibilityGranted = true
            return true
        }

        if prompt, !hasPromptedThisSession {
            hasPromptedThisSession = true
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            _ = AXIsProcessTrustedWithOptions(options)
        }

        isAccessibilityGranted = false
        return false
    }
}
#endif
