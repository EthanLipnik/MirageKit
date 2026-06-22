//
//  MirageRuntimeConditionError.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Expected runtime condition that should be surfaced without treating it as an unexpected crash.
public enum MirageRuntimeConditionError: Int, Error, Sendable, Equatable, Hashable, Comparable, LocalizedError {
    /// Host session is locked and needs unlock before the requested operation can continue.
    case sessionLocked = 1
    /// Host is waiting for local approval before allowing the requested operation.
    case waitingForHostApproval = 2

    /// Sorts runtime conditions by stable raw value for deterministic diagnostics.
    public static func < (lhs: MirageRuntimeConditionError, rhs: MirageRuntimeConditionError) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// User-facing condition message.
    public var message: String {
        switch self {
        case .sessionLocked:
            "Session is locked"
        case .waitingForHostApproval:
            "Waiting for host approval"
        }
    }

    /// Localized error description.
    public var errorDescription: String? {
        message
    }

    /// Diagnostics domain used when grouping expected runtime-condition breadcrumbs.
    public static let diagnosticsDomain = "MirageKit.MirageRuntimeConditionError"
}
