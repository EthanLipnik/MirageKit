//
//  DesktopVirtualDisplayStartupSession.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import CoreGraphics
import Foundation
import MirageKit

#if os(macOS)

/// Error thrown when virtual-display startup exhausts its shared time budget.
struct DesktopVirtualDisplayStartupBudgetExceeded: Error, Equatable {}

/// Shared deadline used by the virtual-display creation and readiness steps.
///
/// The startup path passes one budget through display creation, mode activation,
/// ScreenCaptureKit visibility checks, and retry sleeps so each step clamps its
/// own timeout instead of extending the overall desktop-stream startup window.
struct DesktopVirtualDisplayStartupBudget: Equatable {
    /// Time when the current startup attempt began.
    let startedAt: Date

    /// Maximum wall-clock duration the full startup ladder may spend.
    let maxDuration: TimeInterval

    init(startedAt: Date = Date(), maxDuration: TimeInterval = 10.0) {
        self.startedAt = startedAt
        self.maxDuration = maxDuration
    }

    /// Elapsed time since startup began, expressed for host diagnostics.
    var elapsedMilliseconds: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000.0))
    }

    /// Time remaining before the startup ladder should stop retrying.
    var remainingTimeInterval: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(startedAt))
    }

    /// Whether no budget remains for another blocking operation.
    var isExpired: Bool {
        remainingTimeInterval <= 0
    }

    /// Throws when startup should stop before beginning another operation.
    func checkAvailable() throws {
        if isExpired { throw DesktopVirtualDisplayStartupBudgetExceeded() }
    }

    /// Clamps an operation timeout to the remaining shared startup budget.
    func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        min(timeout, max(0.01, remainingTimeInterval))
    }

    /// Clamps a retry delay to the remaining shared startup budget.
    func boundedDelayMilliseconds(_ milliseconds: Int) -> Int {
        min(milliseconds, max(1, Int(remainingTimeInterval * 1000.0)))
    }
}

/// Category that decides which virtual-display startup fallback is allowed next.
enum DesktopVirtualDisplayStartupFailureClass: Equatable {
    /// Display creation or mode activation failed, so descriptor fallback may help.
    case activation

    /// The system exposed a requested Retina mode as a 1x display, so retry directly at 1x.
    case retinaCollapsedToOneX

    /// The display exists but ScreenCaptureKit or active-display discovery is not ready.
    case readiness

    /// Space assignment or display placement failed.
    case spaceAssignment

    /// The failure is not expected to improve with another startup attempt.
    case nonRetryable
}

/// Tracks one desktop virtual-display startup ladder and its retry decisions.
struct DesktopVirtualDisplayStartupSession {
    /// Ordered startup plan being attempted.
    let plan: DesktopVirtualDisplayStartupPlan

    /// Number of activation-class failures seen in this startup ladder.
    private(set) var activationFailureCount = 0

    /// Number of readiness-class failures seen in this startup ladder.
    private(set) var readinessFailureCount = 0

    /// Number of space-assignment failures seen in this startup ladder.
    private(set) var spaceAssignmentFailureCount = 0

    /// Classifies and records a failed startup step.
    mutating func recordFailure(_ error: Error) -> DesktopVirtualDisplayStartupFailureClass {
        let failureClass = Self.classify(error)
        switch failureClass {
        case .activation:
            activationFailureCount += 1
        case .retinaCollapsedToOneX:
            activationFailureCount += 1
        case .readiness:
            readinessFailureCount += 1
        case .spaceAssignment:
            spaceAssignmentFailureCount += 1
        case .nonRetryable:
            break
        }
        return failureClass
    }

    /// Finds the next plan attempt that is valid after the last failure.
    func nextRetryIndex(
        after failureClass: DesktopVirtualDisplayStartupFailureClass,
        attempts: [DesktopVirtualDisplayStartupAttempt],
        currentIndex: Int
    ) -> Int? {
        let remaining = attempts.indices.filter { $0 > currentIndex }
        for index in remaining {
            if shouldAttemptRetry(after: failureClass, nextAttempt: attempts[index]) {
                return index
            }
        }
        return nil
    }

    /// Returns whether a fallback attempt is appropriate after the observed failure.
    func shouldAttemptRetry(
        after failureClass: DesktopVirtualDisplayStartupFailureClass,
        nextAttempt: DesktopVirtualDisplayStartupAttempt
    ) -> Bool {
        switch nextAttempt.fallbackKind {
        case .primary:
            failureClass != .nonRetryable
        case .descriptorFallback:
            failureClass == .activation
        case .conservative:
            activationFailureCount > 0 || readinessFailureCount > 0 || spaceAssignmentFailureCount > 0
        }
    }

    /// Maps host and framework errors into retry categories.
    static func classify(_ error: Error) -> DesktopVirtualDisplayStartupFailureClass {
        if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
            switch sharedDisplayError {
            case .creationFailed:
                return .activation
            case .retinaCollapsedToOneX:
                return .retinaCollapsedToOneX
            case .spaceNotFound:
                return .spaceAssignment
            case .noActiveDisplay, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound, .streamDisplayNotFound:
                return .readiness
            case .apiNotAvailable:
                return .nonRetryable
            }
        }

        if Self.isScreenCaptureKitContentListUnavailable(error) {
            return .readiness
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case .timeout, .captureSetupFailed:
                return .readiness
            case .alreadyAdvertising,
                 .notAdvertising,
                 .connectionFailed,
                 .connectionRejected,
                 .authenticationFailed,
                 .streamNotFound,
                 .encodingError,
                 .decodingError,
                 .permissionDenied,
                 .protocolError,
                 .windowNotFound:
                return .nonRetryable
            }
        }

        return .nonRetryable
    }

    /// Detects transient ScreenCaptureKit content-list failures seen during display startup.
    private static func isScreenCaptureKitContentListUnavailable(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" else {
            return false
        }
        return [-3813, -3814, -3815].contains(nsError.code)
    }

    /// Records a successful startup target when the runtime display matches the request.
    func persistIfPreferred(
        from snapshot: SharedVirtualDisplayManager.DisplaySnapshot,
        attemptedRefreshRate: Int
    ) {
        let effectiveTier: DesktopVirtualDisplayStartupTargetTier = if snapshot.colorSpace == plan.request.requestedColorSpace,
                                                                       snapshot.refreshRate.rounded() == Double(plan.request.requestedRefreshRate),
                                                                       (snapshot.scaleFactor > 1.5) == plan.request.requestedHiDPI {
            .preferred
        } else {
            .degraded
        }
        recordDesktopVirtualDisplayStartupTargetSuccess(
            pixelResolution: snapshot.resolution,
            scaleFactor: snapshot.scaleFactor,
            refreshRate: Int(snapshot.refreshRate.rounded()),
            colorSpace: snapshot.colorSpace,
            targetTier: effectiveTier,
            for: plan.request
        )
        if effectiveTier == .degraded {
            MirageLogger.host(
                "Desktop virtual display startup succeeded with degraded runtime state; not caching preferred target (requested \(plan.request.requestedColorSpace.displayName)@\(plan.request.requestedRefreshRate)Hz, effective \(snapshot.colorSpace.displayName)@\(Int(snapshot.refreshRate.rounded()))Hz)"
            )
        } else if attemptedRefreshRate != Int(snapshot.refreshRate.rounded()) {
            MirageLogger.host(
                "Desktop virtual display startup refreshed to \(Int(snapshot.refreshRate.rounded()))Hz during activation"
            )
        }
    }
}
#endif
