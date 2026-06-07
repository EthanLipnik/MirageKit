//
//  StreamContext+TransportSendRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//
//  Transport send-error recovery.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
extension StreamContext {
    struct TransportSendErrorTracker {
        var timestamps: [CFAbsoluteTime] = []
        var lastRecoveryTime: CFAbsoluteTime = 0
        var threshold: Int = 6
        var window: CFAbsoluteTime = 1.0
        var cooldown: CFAbsoluteTime = 2.0

        mutating func record(now: CFAbsoluteTime) -> Bool {
            timestamps.append(now)
            timestamps.removeAll { now - $0 > window }
            guard timestamps.count >= max(1, threshold) else { return false }
            if lastRecoveryTime > 0, now - lastRecoveryTime < cooldown {
                return false
            }
            lastRecoveryTime = now
            timestamps.removeAll(keepingCapacity: true)
            return true
        }
    }

    func handleTransportSendError(_ error: Error) async -> Bool {
        var tracker = TransportSendErrorTracker(
            timestamps: transportSendErrorTimestamps,
            lastRecoveryTime: lastTransportSendErrorRecoveryTime,
            threshold: transportSendErrorThreshold,
            window: transportSendErrorWindow,
            cooldown: transportSendErrorRecoveryCooldown
        )
        let now = CFAbsoluteTimeGetCurrent()
        let shouldRecover = tracker.record(now: now)
        transportSendErrorTimestamps = tracker.timestamps
        lastTransportSendErrorRecoveryTime = tracker.lastRecoveryTime
        guard shouldRecover else { return false }

        transportSendErrorBursts &+= 1
        noteLossEvent(reason: "transport send error burst", enablePFrameFEC: true)
        await packetSender?.resetQueue(reason: "transport send error burst")
        clearBackpressureState(log: false)
        keyframeSendDeadline = 0
        lastKeyframeRequestTime = 0
        queueKeyframeIfPossible(
            reason: "Transport send error recovery keyframe",
            checkInFlight: false,
            urgent: true
        )
        MirageLogger.stream(
            "Transport send-error burst recovery for stream \(streamID): error=\(error), bursts=\(transportSendErrorBursts)"
        )
        return true
    }
}
#endif
