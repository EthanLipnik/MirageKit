//
//  AppStreamStartFailureDisposition.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

public enum AppStreamStartFailureDisposition: Equatable {
    case noChange
    case clearPendingPrimaryClaim
}

public func appStreamStartFailureDisposition(
    appStartPending: Bool,
    hasActiveStream: Bool
) -> AppStreamStartFailureDisposition {
    guard appStartPending else { return .noChange }
    guard !hasActiveStream else { return .noChange }
    return .clearPendingPrimaryClaim
}
