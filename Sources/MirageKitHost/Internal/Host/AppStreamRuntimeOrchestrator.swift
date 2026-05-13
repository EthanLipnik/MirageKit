//
//  AppStreamRuntimeOrchestrator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//

import Foundation
import MirageKit

#if os(macOS)
/// Tracks active ownership and runtime encoder policies for multi-window app streams.
actor AppStreamRuntimeOrchestrator {
    /// Current policy state for an app bundle's visible streams.
    struct RuntimePolicySnapshot {
        /// Monotonic value that changes when generated policies change.
        let epoch: UInt64
        /// Stream currently receiving active-live priority.
        let activeStreamID: StreamID?
        /// Whether the active stream changed while producing this snapshot.
        let activeChanged: Bool
        /// Time at which an inactive stream's demotion grace expires, if any.
        let nextPolicyTransitionAt: CFAbsoluteTime?
        /// Per-stream policies to apply to the encoder and inventory.
        let policies: [MirageStreamPolicy]
    }

    /// Mutable runtime state for one app bundle.
    private struct BundleState {
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
    nonisolated static let passiveBitrateFloorBps = 1_000_000

    private var streamToBundle: [StreamID: String] = [:]
    private var bundleStatesByIdentifier: [String: BundleState] = [:]

    /// Returns whether an input event should claim active ownership for its stream.
    nonisolated static func isOwnershipSwitchSignal(_ event: MirageInputEvent) -> Bool {
        switch event {
        case .windowFocus,
             .mouseDown,
             .rightMouseDown,
             .otherMouseDown,
             .hostSystemAction,
             .keyDown:
            true
        case let .scrollWheel(event):
            isScrollOwnershipSwitchSignal(event)
        case let .pointerSampleBatch(batch):
            batch.phase == .began
        case .flagsChanged,
             .mouseMoved,
             .mouseDragged,
             .rightMouseDragged,
             .otherMouseDragged,
             .mouseUp,
             .rightMouseUp,
             .otherMouseUp,
             .magnify,
             .rotate,
             .swipe,
             .windowResize,
             .relativeResize,
             .pixelResize,
             .keyUp:
            false
        }
    }

    /// Returns whether a scroll event begins or resumes active stream ownership.
    nonisolated static func isScrollOwnershipSwitchSignal(_ event: MirageScrollEvent) -> Bool {
        if event.phase == .began { return true }
        return event.phase == .none && event.momentumPhase == .none
    }

    /// Registers a visible stream under a normalized app bundle identifier.
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

    /// Removes a stream from ownership tracking.
    func unregisterStream(streamID: StreamID) {
        guard let key = streamToBundle.removeValue(forKey: streamID),
              var state = bundleStatesByIdentifier[key] else {
            return
        }

        state.streamIDs.remove(streamID)
        state.demotionGraceDeadlineByStreamID.removeValue(forKey: streamID)
        if state.activeStreamID == streamID {
            state.activeStreamID = state.streamIDs.min()
        }

        if state.streamIDs.isEmpty {
            bundleStatesByIdentifier.removeValue(forKey: key)
            return
        }
        bundleStatesByIdentifier[key] = state
    }

    /// Requests active ownership for a stream, applying debounce and dwell guards.
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

    /// Forces active ownership for a stream without debounce or dwell checks.
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

    /// Produces current runtime policies for the visible streams in an app bundle.
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
        if visibleOrdered.count <= 1 {
            state.activeStreamID = visibleOrdered.first
            state.demotionGraceDeadlineByStreamID.removeAll()
        } else {
            state.demotionGraceDeadlineByStreamID = Self.trimDemotionGraceDeadlines(
                deadlines: state.demotionGraceDeadlineByStreamID,
                validStreamIDs: state.streamIDs,
                now: now
            )
            if let activeStreamID = state.activeStreamID {
                state.demotionGraceDeadlineByStreamID.removeValue(forKey: activeStreamID)
            }
        }

        let resolvedActiveFPS = if (activeTargetFPS ?? Self.defaultActiveTargetFPS) >= Self.highRefreshActiveTargetFPS {
            Self.highRefreshActiveTargetFPS
        } else {
            Self.defaultActiveTargetFPS
        }
        let graceLiveStreamIDs = Set(state.demotionGraceDeadlineByStreamID.keys)
        let allowsPassiveSnapshots = visibleOrdered.count > 1

        let bitrateTargets = Self.allocateBitrateTargets(
            streamIDs: visibleOrdered,
            activeStreamID: state.activeStreamID,
            budgetBps: bitrateBudgetBps,
            activeTargetFPS: resolvedActiveFPS
        )

        let policies = visibleOrdered.map { streamID in
            let isPrimaryActive = streamID == state.activeStreamID
            let isGraceActive = allowsPassiveSnapshots && graceLiveStreamIDs.contains(streamID)
            let isLive = isPrimaryActive || isGraceActive
            return MirageStreamPolicy(
                streamID: streamID,
                tier: isLive ? .activeLive : .passiveSnapshot,
                targetFPS: isLive ? resolvedActiveFPS : Self.passiveTargetFPS,
                targetBitrateBps: bitrateTargets[streamID]
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
            epoch: state.epoch,
            activeStreamID: state.activeStreamID,
            activeChanged: activeChanged,
            nextPolicyTransitionAt: nextPolicyTransitionAt,
            policies: policies
        )
    }

    /// Builds a compact identity for policy changes that should bump the epoch.
    private nonisolated static func policyFingerprint(
        activeStreamID: StreamID?,
        policies: [MirageStreamPolicy]
    ) -> String {
        let activeText = activeStreamID.map(String.init) ?? "-"
        let streamText = policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            return "\(policy.streamID):\(policy.tier.rawValue):\(policy.targetFPS):\(bitrate)"
        }.joined(separator: "|")
        return "\(activeText)#\(streamText)"
    }

    /// Allocates a shared bitrate budget between active and passive app streams.
    private nonisolated static func allocateBitrateTargets(
        streamIDs: [StreamID],
        activeStreamID: StreamID?,
        budgetBps: Int?,
        activeTargetFPS: Int
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
        let passiveMinimum = max(1, min(Self.passiveBitrateFloorBps, budgetBps / streamIDs.count))
        let activeWeight = Double(max(Self.defaultActiveTargetFPS, activeTargetFPS))
        let passiveWeight = Double(Self.passiveTargetFPS)
        let totalWeight = activeWeight + (passiveWeight * Double(passiveStreamIDs.count))
        let weightedPassive = Int((Double(budgetBps) * passiveWeight / totalWeight).rounded(.down))
        var passiveTarget = max(passiveMinimum, weightedPassive)
        let maxPassiveTarget = max(1, (budgetBps - 1) / max(1, passiveStreamIDs.count))
        if passiveTarget > maxPassiveTarget {
            passiveTarget = maxPassiveTarget
        }

        let activeTarget = max(1, budgetBps - (passiveTarget * passiveStreamIDs.count))

        var targets: [StreamID: Int] = [activeStreamID: activeTarget]
        for streamID in passiveStreamIDs {
            targets[streamID] = passiveTarget
        }
        return targets
    }

    /// Applies an ownership switch and gives the previous active stream a demotion grace period.
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

    /// Drops expired or no-longer-visible demotion grace deadlines.
    private nonisolated static func trimDemotionGraceDeadlines(
        deadlines: [StreamID: CFAbsoluteTime],
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
