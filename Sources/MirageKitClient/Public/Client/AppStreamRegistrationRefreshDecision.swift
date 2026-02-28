//
//  AppStreamRegistrationRefreshDecision.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  App stream registration refresh decisions.
//

enum AppStreamRegistrationRefreshDecision: Equatable {
    case refreshRegistration
    case reuseRegistration
}

func appStreamRegistrationRefreshDecision(
    hasController: Bool,
    shouldResetController: Bool,
    wasRegistered: Bool
) -> AppStreamRegistrationRefreshDecision {
    if !wasRegistered { return .refreshRegistration }
    if !hasController { return .refreshRegistration }
    if shouldResetController { return .refreshRegistration }
    return .reuseRegistration
}
