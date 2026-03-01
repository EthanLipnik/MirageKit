//
//  AppStreamRuntimeOrchestrator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

#if os(macOS)
actor AppStreamRuntimeOrchestrator {
    struct RuntimePolicySnapshot: Sendable {
        let bundleIdentifier: String
        let epoch: UInt64
        let activeStreamID: StreamID?
        let activeChanged: Bool
        let nextPolicyTransitionAt: CFAbsoluteTime?
        let policies: [MirageStreamPolicy]
    }

    private struct BundleState: Sendable {
        var streamIDs: Set<StreamID> = []
        var activeStreamID: StreamID?
        var lastOwnershipSignalAt: CFAbsoluteTime = 0
        var lastActiveSwitchAt: CFAbsoluteTime = 0
        var demotionGraceDeadlineByStreamID: [StreamID: CFAbsoluteTime] = [:]
        var epoch: UInt64 = 0
        var lastPolicyFingerprint: String = ""
    }

    nonisolated static let ownershipSwitchDebounce: CFAbsoluteTime = 0.150
    nonisolated static let minimumActiveDwell: CFAbsoluteTime = 0.400
    nonisolated static let inactiveDemotionGrace: CFAbsoluteTime = 0.500
    nonisolated static let passiveTargetFPS = 1
    nonisolated static let defaultActiveTargetFPS = 60
    nonisolated static let highRefreshActiveTargetFPS = 120
    nonisolated static let activeBitrateWeight = 0.85
    nonisolated static let passiveBitrateFloorBps = 1_000_000

    private var streamToBundle: [StreamID: String] = [:]
    private var bundleStatesByIdentifier: [String: BundleState] = [:]

    nonisolated static func isOwnershipSwitchSignal(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .windowFocus,
             .mouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .keyDown:
            return true
        case .flagsChanged,
             .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .mouseUp,
             .rightMouseUp,
             .otherMouseUp,
             .scrollWheel,
             .magnify,
             .rotate,
             .windowResize,
             .relativeResize,
             .pixelResize,
             .keyUp:
            return false
        }
    }

    func registerStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        var state = bundleStatesByIdentifier[key] ?? BundleState()
        state.streamIDs.insert(streamID)
        if state.activeStreamID == nil {
            state.activeStreamID = streamID
        }
        bundleStatesByIdentifier[key] = state
        streamToBundle[streamID] = key
    }

    func unregisterStream(streamID: StreamID) {
        guard let key = streamToBundle.removeValue(forKey: streamID),
              var state = bundleStatesByIdentifier[key] else {
            return
        }

        state.streamIDs.remove(streamID)
        state.demotionGraceDeadlineByStreamID.removeValue(forKey: streamID)
        if state.activeStreamID == streamID {
            state.activeStreamID = state.streamIDs.sorted().first
        }

        if state.streamIDs.isEmpty {
            bundleStatesByIdentifier.removeValue(forKey: key)
            return
        }
        bundleStatesByIdentifier[key] = state
    }

    func requestOwnershipSwitch(streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
        guard let key = streamToBundle[streamID],
              var state = bundleStatesByIdentifier[key],
              state.streamIDs.contains(streamID) else {
            return false
        }
        guard state.activeStreamID != streamID else {
            state.lastOwnershipSignalAt = now
            state.demotionGraceDeadlineByStreamID.removeValue(forKey: streamID)
            bundleStatesByIdentifier[key] = state
            return false
        }

        if state.lastOwnershipSignalAt > 0,
           now - state.lastOwnershipSignalAt < Self.ownershipSwitchDebounce {
            return false
        }
        if state.lastActiveSwitchAt > 0,
           now - state.lastActiveSwitchAt < Self.minimumActiveDwell {
            state.lastOwnershipSignalAt = now
            bundleStatesByIdentifier[key] = state
            return false
        }

        Self.applyOwnershipSwitch(
            state: &state,
            streamID: streamID,
            now: now
        )
        bundleStatesByIdentifier[key] = state
        return true
    }

    func forceOwnership(streamID: StreamID, now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) {
        guard let key = streamToBundle[streamID],
              var state = bundleStatesByIdentifier[key],
              state.streamIDs.contains(streamID) else {
            return
        }

        Self.applyOwnershipSwitch(
            state: &state,
            streamID: streamID,
            now: now
        )
        bundleStatesByIdentifier[key] = state
    }

    func makeRuntimePolicySnapshot(
        bundleIdentifier: String,
        visibleStreamIDs: [StreamID],
        bitrateBudgetBps: Int?,
        activeTargetFPS: Int?,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> RuntimePolicySnapshot {
        let key = bundleIdentifier.lowercased()
        let visibleOrdered = Array(Set(visibleStreamIDs)).sorted()
        var state = bundleStatesByIdentifier[key] ?? BundleState()
        let previousActive = state.activeStreamID

        state.streamIDs = Set(visibleOrdered)
        if let active = state.activeStreamID, !state.streamIDs.contains(active) {
            state.activeStreamID = nil
        }
        if state.activeStreamID == nil {
            state.activeStreamID = visibleOrdered.first
        }
        state.demotionGraceDeadlineByStreamID = Self.trimDemotionGraceDeadlines(
            state.demotionGraceDeadlineByStreamID,
            validStreamIDs: state.streamIDs,
            now: now
        )
        if let activeStreamID = state.activeStreamID {
            state.demotionGraceDeadlineByStreamID.removeValue(forKey: activeStreamID)
        }

        let resolvedActiveFPS = if (activeTargetFPS ?? Self.defaultActiveTargetFPS) >= Self.highRefreshActiveTargetFPS {
            Self.highRefreshActiveTargetFPS
        } else {
            Self.defaultActiveTargetFPS
        }
        let graceLiveStreamIDs = Set(state.demotionGraceDeadlineByStreamID.keys)

        let bitrateTargets = Self.allocateBitrateTargets(
            streamIDs: visibleOrdered,
            activeStreamID: state.activeStreamID,
            budgetBps: bitrateBudgetBps
        )

        let policies = visibleOrdered.map { streamID in
            let isPrimaryActive = streamID == state.activeStreamID
            let isGraceActive = graceLiveStreamIDs.contains(streamID)
            let isLive = isPrimaryActive || isGraceActive
            return MirageStreamPolicy(
                streamID: streamID,
                tier: isLive ? .activeLive : .passiveSnapshot,
                targetFPS: isLive ? resolvedActiveFPS : Self.passiveTargetFPS,
                targetBitrateBps: bitrateTargets[streamID],
                recoveryProfile: isPrimaryActive ? .activeAggressive : .passiveBounded
            )
        }
        let nextPolicyTransitionAt = state.demotionGraceDeadlineByStreamID.values.min()

        let fingerprint = Self.policyFingerprint(activeStreamID: state.activeStreamID, policies: policies)
        let activeChanged = previousActive != state.activeStreamID
        if fingerprint != state.lastPolicyFingerprint {
            state.epoch &+= 1
            state.lastPolicyFingerprint = fingerprint
        }

        bundleStatesByIdentifier[key] = state
        return RuntimePolicySnapshot(
            bundleIdentifier: key,
            epoch: state.epoch,
            activeStreamID: state.activeStreamID,
            activeChanged: activeChanged,
            nextPolicyTransitionAt: nextPolicyTransitionAt,
            policies: policies
        )
    }

    private nonisolated static func policyFingerprint(
        activeStreamID: StreamID?,
        policies: [MirageStreamPolicy]
    ) -> String {
        let activeText = activeStreamID.map(String.init) ?? "-"
        let streamText = policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            return "\(policy.streamID):\(policy.tier.rawValue):\(policy.targetFPS):\(bitrate):\(policy.recoveryProfile.rawValue)"
        }.joined(separator: "|")
        return "\(activeText)#\(streamText)"
    }

    private nonisolated static func allocateBitrateTargets(
        streamIDs: [StreamID],
        activeStreamID: StreamID?,
        budgetBps: Int?
    ) -> [StreamID: Int] {
        guard let budgetBps, budgetBps > 0 else { return [:] }
        guard !streamIDs.isEmpty else { return [:] }

        if streamIDs.count == 1, let streamID = streamIDs.first {
            return [streamID: max(Self.passiveBitrateFloorBps, budgetBps)]
        }

        guard let activeStreamID, streamIDs.contains(activeStreamID) else {
            let shared = max(Self.passiveBitrateFloorBps, budgetBps / streamIDs.count)
            return Dictionary(uniqueKeysWithValues: streamIDs.map { ($0, shared) })
        }

        let passiveStreamIDs = streamIDs.filter { $0 != activeStreamID }
        let passiveFloorTotal = Self.passiveBitrateFloorBps * passiveStreamIDs.count
        let weightedActive = Int(Double(budgetBps) * Self.activeBitrateWeight)
        var activeTarget = max(Self.passiveBitrateFloorBps, weightedActive)
        if activeTarget + passiveFloorTotal > budgetBps {
            activeTarget = max(Self.passiveBitrateFloorBps, budgetBps - passiveFloorTotal)
        }

        var remaining = max(0, budgetBps - activeTarget)
        let passiveShare = passiveStreamIDs.isEmpty ? 0 : max(
            Self.passiveBitrateFloorBps,
            remaining / passiveStreamIDs.count
        )
        remaining = max(0, remaining - (passiveShare * passiveStreamIDs.count))

        var targets: [StreamID: Int] = [activeStreamID: activeTarget]
        for streamID in passiveStreamIDs {
            var target = passiveShare
            if remaining > 0 {
                target += 1
                remaining -= 1
            }
            targets[streamID] = max(Self.passiveBitrateFloorBps, target)
        }
        return targets
    }

    private nonisolated static func applyOwnershipSwitch(
        state: inout BundleState,
        streamID: StreamID,
        now: CFAbsoluteTime
    ) {
        let previousActive = state.activeStreamID
        state.activeStreamID = streamID
        state.lastOwnershipSignalAt = now
        state.lastActiveSwitchAt = now
        state.demotionGraceDeadlineByStreamID.removeValue(forKey: streamID)

        guard let previousActive, previousActive != streamID else { return }
        state.demotionGraceDeadlineByStreamID[previousActive] = now + Self.inactiveDemotionGrace
    }

    private nonisolated static func trimDemotionGraceDeadlines(
        _ deadlines: [StreamID: CFAbsoluteTime],
        validStreamIDs: Set<StreamID>,
        now: CFAbsoluteTime
    ) -> [StreamID: CFAbsoluteTime] {
        deadlines.reduce(into: [:]) { partialResult, entry in
            let (streamID, deadline) = entry
            guard validStreamIDs.contains(streamID), deadline > now else { return }
            partialResult[streamID] = deadline
        }
    }
}
#endif
