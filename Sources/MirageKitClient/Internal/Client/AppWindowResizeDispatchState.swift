//
//  AppWindowResizeDispatchState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
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
import CoreGraphics
import Foundation

/// Coalesces client-driven app-window resize requests so only one host resize is in flight.
struct AppWindowResizeDispatchState: Equatable {
    static let minimumDispatchInterval: CFAbsoluteTime = 0.10
    static let repeatedFailureBackoff: CFAbsoluteTime = 0.35
    static let repeatedFailureThreshold = 2

    private(set) var inFlightTarget: CGSize?
    private(set) var pendingTarget: CGSize?
    private(set) var coalescedCount: UInt64 = 0
    private(set) var consecutiveFailureCount: Int = 0
    private(set) var lastObservedSize: CGSize?
    private(set) var lastDispatchTime: CFAbsoluteTime = 0
    private(set) var backoffUntil: CFAbsoluteTime = 0

    private var lastCompletedTarget: CGSize?
    private var lastCompletedOutcome: MirageWire.MirageAppWindowResizeResultOutcome?

    var hasInFlightResize: Bool {
        inFlightTarget != nil
    }

    var hasPendingResize: Bool {
        pendingTarget != nil
    }

    var diagnosticSummary: String {
        "inFlight=\(Self.format(inFlightTarget)) " +
            "pending=\(Self.format(pendingTarget)) " +
            "coalesced=\(coalescedCount) " +
            "failedConsecutive=\(consecutiveFailureCount) " +
            "lastObserved=\(Self.format(lastObservedSize))"
    }

    mutating func enqueue(_ target: CGSize) {
        let target = normalizedTarget(target)
        guard target.width > 0, target.height > 0 else { return }

        if let inFlightTarget {
            guard target != inFlightTarget else {
                if pendingTarget != nil {
                    coalescedCount &+= 1
                    pendingTarget = nil
                }
                return
            }
            if pendingTarget != target {
                coalescedCount &+= 1
            }
            pendingTarget = target
            return
        }

        if target == lastCompletedTarget, lastCompletedOutcome != .failed {
            return
        }

        if pendingTarget == target { return }
        if pendingTarget != nil {
            coalescedCount &+= 1
        }
        pendingTarget = target
    }

    func dispatchDelay(now: CFAbsoluteTime) -> CFAbsoluteTime? {
        guard inFlightTarget == nil, pendingTarget != nil else { return nil }
        let nextAllowedTime = max(lastDispatchTime + Self.minimumDispatchInterval, backoffUntil)
        return max(0, nextAllowedTime - now)
    }

    mutating func beginNextDispatch(now: CFAbsoluteTime) -> CGSize? {
        guard inFlightTarget == nil, let target = pendingTarget else { return nil }
        pendingTarget = nil
        inFlightTarget = target
        lastDispatchTime = now
        return target
    }

    mutating func complete(result: MirageWire.AppWindowResizeResultMessage, now: CFAbsoluteTime) -> Bool {
        if let observedWidth = result.observedWidth,
           let observedHeight = result.observedHeight,
           observedWidth > 0,
           observedHeight > 0 {
            lastObservedSize = CGSize(width: observedWidth, height: observedHeight)
        }

        guard let inFlightTarget,
              Self.result(result, matches: inFlightTarget) else {
            return false
        }

        completeCurrentResize(
            target: inFlightTarget,
            outcome: result.outcome,
            reason: result.reason,
            now: now
        )
        return true
    }

    mutating func completeCurrentAsSendFailed(now: CFAbsoluteTime) {
        guard let inFlightTarget else { return }
        completeCurrentResize(
            target: inFlightTarget,
            outcome: .failed,
            reason: "sendFailed",
            now: now
        )
    }

    mutating func completeCurrentAsAcknowledged(now: CFAbsoluteTime) {
        guard let inFlightTarget else { return }
        completeCurrentResize(
            target: inFlightTarget,
            outcome: .applied,
            reason: nil,
            now: now
        )
    }

    mutating func completeCurrentAsTimedOut(now: CFAbsoluteTime) {
        guard let inFlightTarget else { return }
        completeCurrentResize(
            target: inFlightTarget,
            outcome: .failed,
            reason: "ackTimeout",
            now: now
        )
    }

    mutating func cancel() {
        inFlightTarget = nil
        pendingTarget = nil
        backoffUntil = 0
    }

    private mutating func completeCurrentResize(
        target: CGSize,
        outcome: MirageWire.MirageAppWindowResizeResultOutcome,
        reason: String?,
        now: CFAbsoluteTime
    ) {
        inFlightTarget = nil
        lastCompletedTarget = target
        lastCompletedOutcome = outcome

        if Self.countsAsFailure(outcome: outcome, reason: reason) {
            consecutiveFailureCount += 1
            if consecutiveFailureCount >= Self.repeatedFailureThreshold {
                backoffUntil = max(backoffUntil, now + Self.repeatedFailureBackoff)
            }
        } else {
            consecutiveFailureCount = 0
            backoffUntil = 0
        }
    }

    private func normalizedTarget(_ target: CGSize) -> CGSize {
        MirageMedia.MirageStreamGeometry.normalizedLogicalSize(target)
    }

    private static func result(
        _ result: MirageWire.AppWindowResizeResultMessage,
        matches target: CGSize
    ) -> Bool {
        Int(target.width) == result.requestedWidth &&
            Int(target.height) == result.requestedHeight
    }

    private static func countsAsFailure(
        outcome: MirageWire.MirageAppWindowResizeResultOutcome,
        reason: String?
    ) -> Bool {
        guard outcome == .failed else { return false }
        guard let reason else { return true }
        return reason.localizedCaseInsensitiveContains("didNotConverge") ||
            reason.localizedCaseInsensitiveContains("failed") ||
            reason.localizedCaseInsensitiveContains("timeout") ||
            reason.localizedCaseInsensitiveContains("send")
    }

    private static func format(_ size: CGSize?) -> String {
        guard let size, size.width > 0, size.height > 0 else { return "none" }
        return "\(Int(size.width))x\(Int(size.height))"
    }
}
