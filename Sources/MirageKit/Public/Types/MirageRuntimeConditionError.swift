//
//  MirageRuntimeConditionError.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Typed runtime conditions that are expected under specific host/client states.
//

import Foundation

public enum MirageRuntimeConditionError: Int, Error, Sendable, Equatable, Hashable, Comparable, LocalizedError {
    case sessionLocked = 1
    case waitingForHostApproval = 2

    public static func < (lhs: MirageRuntimeConditionError, rhs: MirageRuntimeConditionError) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var message: String {
        switch self {
        case .sessionLocked:
            "Session is locked"
        case .waitingForHostApproval:
            "Waiting for host approval"
        }
    }

    public var errorDescription: String? {
        message
    }

    public static var diagnosticsDomain: String {
        String(reflecting: MirageRuntimeConditionError.self)
    }
}
