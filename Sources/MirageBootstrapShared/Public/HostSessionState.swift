//
//  HostSessionState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared host session state and unlock error types used by bootstrap flows.
//

import Foundation

public enum HostSessionState: String, Codable, Sendable {
    case active
    case screenLocked
    case loginScreen
    case sleeping

    public var requiresUnlock: Bool {
        switch self {
        case .active:
            false
        case .screenLocked,
             .loginScreen,
             .sleeping:
            true
        }
    }

    public var requiresUsername: Bool {
        switch self {
        case .loginScreen:
            true
        case .active,
             .screenLocked,
             .sleeping:
            false
        }
    }
}

public struct UnlockError: Codable, Sendable, Equatable {
    public let code: UnlockErrorCode
    public let message: String

    public init(code: UnlockErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public enum UnlockErrorCode: String, Codable, Sendable {
    case invalidCredentials
    case rateLimited
    case sessionExpired
    case notLocked
    case notSupported
    case notAuthorized
    case timeout
    case internalError
}
