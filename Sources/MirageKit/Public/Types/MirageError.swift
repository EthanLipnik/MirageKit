//
//  MirageError.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/4/26.
//
//  Shared Mirage error definitions.
//

import Foundation

public enum MirageError: Error, LocalizedError {
    case alreadyAdvertising
    case notAdvertising
    case connectionFailed(Error)
    case authenticationFailed
    case streamNotFound
    case windowNotFound
    case encodingError(Error)
    case decodingError(Error)
    case permissionDenied
    case timeout
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyAdvertising:
            "Already advertising service"
        case .notAdvertising:
            "Not currently advertising"
        case let .connectionFailed(error):
            "Connection failed: \(error.localizedDescription)"
        case .authenticationFailed:
            "Authentication failed"
        case .streamNotFound:
            "Stream not found"
        case .windowNotFound:
            "Window not found"
        case let .encodingError(error):
            "Encoding error: \(error.localizedDescription)"
        case let .decodingError(error):
            "Decoding error: \(error.localizedDescription)"
        case .permissionDenied:
            "Permission denied"
        case .timeout:
            "Operation timed out"
        case let .protocolError(message):
            "Protocol error: \(message)"
        }
    }
}
