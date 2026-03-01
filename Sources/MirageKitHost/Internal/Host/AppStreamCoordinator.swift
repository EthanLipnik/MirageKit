//
//  AppStreamCoordinator.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//

import Foundation
import MirageKit

#if os(macOS)
enum AppStreamRuntimeTier: String, Sendable {
    case activeLive
    case passiveSnapshot
}

actor AppStreamCoordinator {
    struct StreamRuntimePlan: Sendable {
        let streamID: StreamID
        let tier: AppStreamRuntimeTier
        let tierChanged: Bool
        let targetFrameRate: Int
        let targetBitrateBps: Int?
    }

    struct SessionPlan: Sendable {
        let bundleIdentifier: String
        let activeStreamID: StreamID?
        let activeStreamChanged: Bool
        let streamPlans: [StreamRuntimePlan]
    }

    private struct BundleState: Sendable {
        var streamIDs: Set<StreamID> = []
        var activeStreamID: StreamID?
    }

    private var streamToBundle: [StreamID: String] = [:]
    private var bundleStateByIdentifier: [String: BundleState] = [:]
    private var lastPlannedTierByStreamID: [StreamID: AppStreamRuntimeTier] = [:]
    private var lastPlannedActiveStreamIDByBundle: [String: StreamID] = [:]

    func registerStream(bundleIdentifier: String, streamID: StreamID) {
        let key = bundleIdentifier.lowercased()
        var state = bundleStateByIdentifier[key] ?? BundleState()
        state.streamIDs.insert(streamID)
        if state.activeStreamID == nil {
            state.activeStreamID = streamID
        }
        bundleStateByIdentifier[key] = state
        streamToBundle[streamID] = key
    }

    func unregisterStream(streamID: StreamID) {
        guard let key = streamToBundle.removeValue(forKey: streamID) else { return }
        lastPlannedTierByStreamID.removeValue(forKey: streamID)
        guard var state = bundleStateByIdentifier[key] else { return }
        state.streamIDs.remove(streamID)
        if state.activeStreamID == streamID {
            state.activeStreamID = state.streamIDs.sorted().first
        }
        if state.streamIDs.isEmpty {
            bundleStateByIdentifier.removeValue(forKey: key)
            lastPlannedActiveStreamIDByBundle.removeValue(forKey: key)
        } else {
            bundleStateByIdentifier[key] = state
        }
    }

    func forceActiveStream(streamID: StreamID) {
        guard let key = streamToBundle[streamID],
              var state = bundleStateByIdentifier[key],
              state.streamIDs.contains(streamID) else {
            return
        }

        state.activeStreamID = streamID
        bundleStateByIdentifier[key] = state
    }

    func makeSessionPlan(
        bundleIdentifier: String,
        visibleStreamIDs: [StreamID],
        bitrateBudgetBps: Int?
    ) -> SessionPlan {
        let key = bundleIdentifier.lowercased()
        var state = bundleStateByIdentifier[key] ?? BundleState()
        let previousStreamIDs = state.streamIDs
        let visibleSet = Set(visibleStreamIDs)

        state.streamIDs.formUnion(visibleSet)
        state.streamIDs = state.streamIDs.intersection(visibleSet)
        for staleStreamID in previousStreamIDs where !visibleSet.contains(staleStreamID) {
            lastPlannedTierByStreamID.removeValue(forKey: staleStreamID)
        }

        if let active = state.activeStreamID,
           !state.streamIDs.contains(active) {
            state.activeStreamID = nil
        }
        if state.activeStreamID == nil {
            state.activeStreamID = visibleStreamIDs.sorted().first
        }

        bundleStateByIdentifier[key] = state
        let activeStreamID = state.activeStreamID
        let previousPlannedActiveStreamID = lastPlannedActiveStreamIDByBundle[key]
        let activeStreamChanged = activeStreamID != previousPlannedActiveStreamID
        if let activeStreamID {
            lastPlannedActiveStreamIDByBundle[key] = activeStreamID
        } else {
            lastPlannedActiveStreamIDByBundle.removeValue(forKey: key)
        }

        let passiveCount = max(0, visibleStreamIDs.count - (activeStreamID == nil ? 0 : 1))
        let passiveFrameRate = Self.passiveFrameRate(passiveCount: passiveCount)
        let bitrateTargets = Self.makeBitrateTargets(
            streamIDs: visibleStreamIDs,
            activeStreamID: activeStreamID,
            budgetBps: bitrateBudgetBps
        )

        let streamPlans = visibleStreamIDs.sorted().map { streamID in
            let tier: AppStreamRuntimeTier = streamID == activeStreamID ? .activeLive : .passiveSnapshot
            let previousTier = lastPlannedTierByStreamID[streamID]
            return StreamRuntimePlan(
                streamID: streamID,
                tier: tier,
                tierChanged: previousTier != tier,
                targetFrameRate: tier == .activeLive ? 60 : passiveFrameRate,
                targetBitrateBps: bitrateTargets[streamID]
            )
        }
        for streamPlan in streamPlans {
            lastPlannedTierByStreamID[streamPlan.streamID] = streamPlan.tier
        }

        return SessionPlan(
            bundleIdentifier: key,
            activeStreamID: activeStreamID,
            activeStreamChanged: activeStreamChanged,
            streamPlans: streamPlans
        )
    }

    private nonisolated static func passiveFrameRate(passiveCount: Int) -> Int {
        guard passiveCount > 0 else { return 2 }
        if passiveCount <= 2 { return 4 }
        if passiveCount >= 6 { return 1 }
        return 2
    }

    private nonisolated static func makeBitrateTargets(
        streamIDs: [StreamID],
        activeStreamID: StreamID?,
        budgetBps: Int?
    ) -> [StreamID: Int] {
        guard let budgetBps, budgetBps > 0 else {
            return [:]
        }

        let sortedStreamIDs = streamIDs.sorted()
        guard !sortedStreamIDs.isEmpty else { return [:] }

        if sortedStreamIDs.count == 1,
           let only = sortedStreamIDs.first {
            return [only: max(1_000_000, budgetBps)]
        }

        guard let activeStreamID,
              sortedStreamIDs.contains(activeStreamID) else {
            let shared = max(1_000_000, budgetBps / sortedStreamIDs.count)
            return Dictionary(uniqueKeysWithValues: sortedStreamIDs.map { ($0, shared) })
        }

        let passiveStreamIDs = sortedStreamIDs.filter { $0 != activeStreamID }
        let passiveCount = passiveStreamIDs.count
        let passiveFloorTotal = 1_000_000 * passiveCount

        var activeTarget = max(5_000_000, Int(Double(budgetBps) * 0.72))
        if activeTarget + passiveFloorTotal > budgetBps {
            activeTarget = max(1_000_000, budgetBps - passiveFloorTotal)
        }

        var remaining = max(0, budgetBps - activeTarget)
        let passiveShare = passiveCount > 0 ? max(1_000_000, remaining / passiveCount) : 0
        remaining = max(0, remaining - (passiveShare * passiveCount))

        var targets: [StreamID: Int] = [activeStreamID: max(1_000_000, activeTarget)]
        for passiveStreamID in passiveStreamIDs {
            var target = passiveShare
            if remaining > 0 {
                target += 1
                remaining -= 1
            }
            targets[passiveStreamID] = max(1_000_000, target)
        }
        return targets
    }
}
#endif
