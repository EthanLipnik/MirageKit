//
//  HostAudioLivenessPolicy.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/5/26.
//
//  Host audio capture first-sample watchdog policy.
//

import Foundation
import MirageKit

#if os(macOS)

enum HostAudioFirstSampleWatchdogDecision: Equatable {
    case ignore
    case retryCapture
    case fail
}

struct HostAudioFirstSampleWatchdogPolicy {
    static func decision(
        audioEnabled: Bool,
        pipelineActive: Bool,
        sourceMatches: Bool,
        lastSampleTime: CFAbsoluteTime?,
        activationTime: CFAbsoluteTime,
        retryAttempted: Bool
    ) -> HostAudioFirstSampleWatchdogDecision {
        guard audioEnabled, pipelineActive, sourceMatches else { return .ignore }
        if let lastSampleTime, lastSampleTime >= activationTime {
            return .ignore
        }
        return retryAttempted ? .fail : .retryCapture
    }
}

#endif
