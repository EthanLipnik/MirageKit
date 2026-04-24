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

struct DesktopVirtualDisplayStartupBudgetExceeded: Error, Equatable {}

struct DesktopVirtualDisplayStartupBudget: Equatable {
    let startedAt: Date
    let maxDuration: TimeInterval

    init(startedAt: Date = Date(), maxDuration: TimeInterval = 10.0) {
        self.startedAt = startedAt
        self.maxDuration = maxDuration
    }

    var elapsedMilliseconds: Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000.0))
    }

    var remainingTimeInterval: TimeInterval {
        max(0, maxDuration - Date().timeIntervalSince(startedAt))
    }

    var isExpired: Bool {
        remainingTimeInterval <= 0
    }

    func checkAvailable() throws {
        if isExpired { throw DesktopVirtualDisplayStartupBudgetExceeded() }
    }

    func boundedTimeout(_ timeout: TimeInterval) -> TimeInterval {
        min(timeout, max(0.01, remainingTimeInterval))
    }

    func boundedDelayMilliseconds(_ milliseconds: Int) -> Int {
        min(milliseconds, max(1, Int(remainingTimeInterval * 1000.0)))
    }
}

enum DesktopVirtualDisplayStartupPhase: Equatable {
    case planning
    case acquiring(String)
    case waitingForCaptureDisplay(CGDirectDisplayID)
    case ready(CGDirectDisplayID)
    case tearingDown(CGDirectDisplayID)
    case failed(String)
}

enum DesktopVirtualDisplayStartupFailureClass: Equatable {
    case activation
    case readiness
    case spaceAssignment
    case nonRetryable
}

struct DesktopVirtualDisplayStartupSession {
    let plan: DesktopVirtualDisplayStartupPlan
    private(set) var phase: DesktopVirtualDisplayStartupPhase = .planning
    private(set) var activationFailureCount = 0
    private(set) var readinessFailureCount = 0
    private(set) var spaceAssignmentFailureCount = 0

    mutating func begin(_ attempt: DesktopVirtualDisplayStartupAttempt) {
        phase = .acquiring(attempt.label)
    }

    mutating func awaitingCaptureDisplay(displayID: CGDirectDisplayID) {
        phase = .waitingForCaptureDisplay(displayID)
    }

    mutating func ready(displayID: CGDirectDisplayID) {
        phase = .ready(displayID)
    }

    mutating func beginTeardown(displayID: CGDirectDisplayID) {
        phase = .tearingDown(displayID)
    }

    mutating func recordFailure(_ error: Error) -> DesktopVirtualDisplayStartupFailureClass {
        phase = .failed(String(describing: error))
        let failureClass = Self.classify(error)
        switch failureClass {
        case .activation:
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
            readinessFailureCount > 0 || spaceAssignmentFailureCount > 0
        }
    }

    static func classify(_ error: Error) -> DesktopVirtualDisplayStartupFailureClass {
        if let sharedDisplayError = error as? SharedVirtualDisplayManager.SharedDisplayError {
            switch sharedDisplayError {
            case .creationFailed:
                return .activation
            case .spaceNotFound:
                return .spaceAssignment
            case .noActiveDisplay, .screenCaptureKitVisibilityDelayed, .scDisplayNotFound, .streamDisplayNotFound:
                return .readiness
            case .apiNotAvailable:
                return .nonRetryable
            }
        }

        if let mirageError = error as? MirageError {
            switch mirageError {
            case .timeout, .captureSetupFailed:
                return .readiness
            case .alreadyAdvertising,
                 .notAdvertising,
                 .connectionFailed,
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
