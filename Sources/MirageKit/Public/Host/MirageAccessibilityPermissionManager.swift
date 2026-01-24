//
//  MirageAccessibilityPermissionManager.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/21/26.
//

#if os(macOS)
import Foundation
@preconcurrency import ApplicationServices
import Observation

/// Manages accessibility permission state and checking for input injection.
@Observable
@MainActor
public final class MirageAccessibilityPermissionManager {
    /// Current cached permission state.
    public private(set) var isAccessibilityGranted: Bool = false

    /// Whether we've shown the initial prompt this session.
    private var hasPromptedThisSession = false

    /// Rate-limiting for failed injection logs.
    private var lastFailureLogTime: Date?
    private var suppressedFailureCount = 0
    private let failureLogInterval: TimeInterval = 5.0

    public init() {
        refreshPermissionState()
    }

    /// Refresh the current permission state from the system.
    public func refreshPermissionState() {
        isAccessibilityGranted = AXIsProcessTrusted()
    }

    /// Check permission and optionally prompt user.
    /// - Parameter prompt: Whether to show the system permission prompt if not granted.
    /// - Returns: true if permission is granted.
    /// - Note: The prompt is shown at most once per process session.
    @discardableResult
    public func checkAndPromptIfNeeded(prompt: Bool = true) -> Bool {
        if AXIsProcessTrusted() {
            isAccessibilityGranted = true
            return true
        }

        if prompt && !hasPromptedThisSession {
            hasPromptedThisSession = true
            let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true]
            _ = AXIsProcessTrustedWithOptions(options)
        }

        isAccessibilityGranted = false
        return false
    }

    /// Log a permission failure with rate limiting to avoid log spam.
    /// - Parameter eventType: Description of the event type that failed.
    /// - Returns: true if the failure was logged, false if suppressed due to rate limiting.
    /// - Note: Failures are logged as `LogCategory.accessibility` errors.
    @discardableResult
    public func logInjectionFailure(eventType: String) -> Bool {
        let now = Date()

        if let lastLog = lastFailureLogTime,
           now.timeIntervalSince(lastLog) < failureLogInterval {
            suppressedFailureCount += 1
            return false
        }

        if suppressedFailureCount > 0 {
            MirageLogger.error(.accessibility, "Input injection failed for \(eventType) (permission denied). \(suppressedFailureCount) similar failures suppressed.")
        } else {
            MirageLogger.error(.accessibility, "Input injection failed for \(eventType) - accessibility permission not granted")
        }

        lastFailureLogTime = now
        suppressedFailureCount = 0
        return true
    }

    /// Reset rate limiting state (call when permission state changes).
    public func resetRateLimiting() {
        lastFailureLogTime = nil
        suppressedFailureCount = 0
    }
}
#endif
