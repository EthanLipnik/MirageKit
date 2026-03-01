//
//  HostInputActivationPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Input-triggered host window activation policy.
//

import Foundation
import MirageKit
#if os(macOS)

enum HostInputActivationTrigger: Sendable, Equatable {
    case windowFocus
}

enum HostInputActivationAction: Sendable, Equatable {
    case none
    case fullWindowRaise
}

enum HostInputActivationPolicy {
    static let throttleInterval: CFAbsoluteTime = 0.25

    static func action(
        for trigger: HostInputActivationTrigger,
        lastActivationTime: CFAbsoluteTime?,
        lastActivatedWindowID: WindowID?,
        targetWindowID: WindowID,
        now: CFAbsoluteTime,
        throttleInterval: CFAbsoluteTime = Self.throttleInterval
    ) -> HostInputActivationAction {
        switch trigger {
        case .windowFocus:
            // Cross-window focus switches should always activate immediately.
            if lastActivatedWindowID != targetWindowID {
                return .fullWindowRaise
            }

            guard shouldAllowThrottledActivation(
                lastActivationTime: lastActivationTime,
                now: now,
                throttleInterval: throttleInterval
            ) else {
                return .none
            }
            return .fullWindowRaise
        }
    }

    private static func shouldAllowThrottledActivation(
        lastActivationTime: CFAbsoluteTime?,
        now: CFAbsoluteTime,
        throttleInterval: CFAbsoluteTime
    ) -> Bool {
        guard let lastActivationTime else { return true }
        return now - lastActivationTime >= throttleInterval
    }
}

#endif
