//
//  MirageHostService+AppStreaming+Governance.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/27/26.
//
//  App-streaming runtime coordination (active live + passive snapshot tiers).
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit

@MainActor
extension MirageHostService {
    nonisolated static let appStreamMaxVisibleSlots = 8
    nonisolated static let minimumSharedBitrateBudgetBps = 1_000_000
    nonisolated static let appStreamMultiWindowBitrateCapBps = 120_000_000

    func resolvedMaxVisibleAppWindowSlots(_ requestedSlots: Int) -> Int {
        max(1, min(Self.appStreamMaxVisibleSlots, requestedSlots))
    }

    nonisolated static func appStreamPerStreamBitrateCap(visibleStreamCount: Int) -> Int {
        visibleStreamCount > 1 ? appStreamMultiWindowBitrateCapBps : Int.max
    }

    func resolvedAppSessionBitrateBudget(requestedBitrate: Int?) -> Int? {
        let sourceBitrate = requestedBitrate ??
            encoderConfig.bitrate ??
            MirageEncoderConfiguration.highQuality.bitrate
        guard let sourceBitrate else { return nil }
        let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: sourceBitrate) ?? sourceBitrate
        return max(Self.minimumSharedBitrateBudgetBps, normalized)
    }

    func sendAppWindowInventoryUpdate(bundleIdentifier: String, clientID: UUID) async {
        guard let inventory = await appStreamManager.inventoryMessage(bundleIdentifier: bundleIdentifier) else { return }
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        do {
            try await clientContext.send(.appWindowInventory, content: inventory)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send app window inventory update: ")
        }
    }

    func sendAppWindowInventoryUpdate(bundleIdentifier: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return }
        await sendAppWindowInventoryUpdate(bundleIdentifier: bundleIdentifier, clientID: session.clientID)
    }

    func startAppStreamGovernorsIfNeeded() async {
        await refreshAppStreamGovernors(reason: "event")
    }

    func stopAppStreamGovernorsIfIdle() async {
        // Runtime is event-driven and does not keep a background governor task.
    }

    func refreshAppStreamGovernors(reason: String) async {
        let sessions = await appStreamManager.getAllSessions().filter { $0.state == .streaming }
        for session in sessions {
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: session.bundleIdentifier,
                reason: reason
            )
        }
    }

    nonisolated func noteAppStreamInputSignal(streamID: StreamID) {
        dispatchMainWork { [weak self] in
            guard let self else { return }
            await self.markAppStreamInteraction(
                streamID: streamID,
                reason: "input-fast-path",
                forceOwnershipSwitch: false
            )
        }
    }

    func handleAppStreamOwnershipSignal(
        streamID: StreamID,
        event: MirageInputEvent,
        reason: String
    ) async {
        let shouldSwitch = await inputOwnershipGate.considerSignal(
            streamID: streamID,
            event: event,
            hostKeyWindowEligible: isHostKeyWindowEligibleForOwnershipSwitch()
        )
        guard shouldSwitch else { return }

        await markAppStreamInteraction(
            streamID: streamID,
            reason: reason,
            forceOwnershipSwitch: true
        )
    }

    private func isHostKeyWindowEligibleForOwnershipSwitch() -> Bool {
        guard NSApp.isActive,
              let keyWindow = NSApp.keyWindow else {
            return false
        }

        return keyWindow.isVisible && !keyWindow.isMiniaturized
    }

    func markAppStreamInteraction(
        streamID: StreamID,
        reason: String,
        forceOwnershipSwitch: Bool = true
    ) async {
        guard let session = await appStreamManager.getSessionForStreamID(streamID) else { return }

        if forceOwnershipSwitch {
            await inputOwnershipGate.forceOwnership(streamID: streamID)
            await appStreamCoordinator.forceActiveStream(streamID: streamID)
        }

        await recomputeAppSessionBitrateBudget(
            bundleIdentifier: session.bundleIdentifier,
            reason: "interaction:\(reason)"
        )
    }

    func setAppStreamFrontmostSignal(streamID: StreamID, isActive: Bool, reason: String) async {
        guard isActive else { return }
        await markAppStreamInteraction(
            streamID: streamID,
            reason: "frontmost:\(reason)",
            forceOwnershipSwitch: true
        )
    }

    func registerAppStreamDesiredFrameRate(streamID _: StreamID, frameRate _: Int) {
        // Runtime keeps a fixed active baseline and adaptive passive snapshot cadence.
    }

    func clearAppStreamGovernorState(streamID: StreamID) {
        stopWindowVisibleFrameMonitor(streamID: streamID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
        windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
        windowResizeInFlightStreamIDs.remove(streamID)
        Task {
            await inputOwnershipGate.clear(streamID: streamID)
            await appStreamCoordinator.unregisterStream(streamID: streamID)
            await appStreamDisplayAllocator.unbind(streamID: streamID)
            await liveWindowPipeline.clear(streamID: streamID)
            await snapshotWindowPipeline.clear(streamID: streamID)
        }
    }

    func refreshAppStreamActivity(streamID: StreamID, reason: String) async {
        await markAppStreamInteraction(
            streamID: streamID,
            reason: reason,
            forceOwnershipSwitch: false
        )
    }

    func recomputeAppSessionBitrateBudget(bundleIdentifier: String, reason: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return }

        let visibleStreamIDs = session.windowStreams
            .values
            .map(\.streamID)
            .sorted()

        guard !visibleStreamIDs.isEmpty else {
            await appStreamManager.setStreamBitrateTargets(bundleIdentifier: bundleIdentifier, targets: [:])
            return
        }

        for streamID in visibleStreamIDs {
            await appStreamCoordinator.registerStream(
                bundleIdentifier: bundleIdentifier,
                streamID: streamID
            )
        }

        let resolvedBudget = session.bitrateBudgetBps ??
            resolvedAppSessionBitrateBudget(requestedBitrate: nil)

        let plan = await appStreamCoordinator.makeSessionPlan(
            bundleIdentifier: bundleIdentifier,
            visibleStreamIDs: visibleStreamIDs,
            bitrateBudgetBps: resolvedBudget
        )

        var appliedTargets: [StreamID: Int] = [:]
        for streamPlan in plan.streamPlans {
            let isActive = streamPlan.tier == .activeLive
            await appStreamManager.markStreamActivity(
                bundleIdentifier: bundleIdentifier,
                streamID: streamPlan.streamID,
                isActive: isActive
            )

            if let bitrate = streamPlan.targetBitrateBps {
                appliedTargets[streamPlan.streamID] = bitrate
            }

            guard let context = streamsByID[streamPlan.streamID] else { continue }
            if isActive {
                ensureWindowVisibleFrameMonitor(streamID: streamPlan.streamID)
                await appStreamDisplayAllocator.bindLive(streamID: streamPlan.streamID)
                await liveWindowPipeline.apply(
                    streamID: streamPlan.streamID,
                    context: context,
                    targetFrameRate: streamPlan.targetFrameRate,
                    targetBitrateBps: streamPlan.targetBitrateBps,
                    requestRecoveryKeyframe: plan.activeStreamChanged && plan.activeStreamID == streamPlan.streamID
                )
            } else {
                stopWindowVisibleFrameMonitor(streamID: streamPlan.streamID)
                pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamPlan.streamID)
                windowResizeRequestCounterByStreamID.removeValue(forKey: streamPlan.streamID)
                await appStreamDisplayAllocator.bindSnapshot(streamID: streamPlan.streamID)
                await snapshotWindowPipeline.apply(
                    streamID: streamPlan.streamID,
                    context: context,
                    targetFrameRate: streamPlan.targetFrameRate,
                    targetBitrateBps: streamPlan.targetBitrateBps
                )
            }
        }

        await appStreamManager.setStreamBitrateTargets(
            bundleIdentifier: bundleIdentifier,
            targets: appliedTargets
        )

        let activeText = plan.activeStreamID.map(String.init) ?? "none"
        let targetsText = plan.streamPlans.map { plan in
            let bitrate = plan.targetBitrateBps.map(String.init) ?? "auto"
            return "\(plan.streamID)=\(plan.tier.rawValue):\(plan.targetFrameRate)fps@\(bitrate)"
        }.joined(separator: ", ")

        MirageLogger.host(
            "App-stream runtime update (\(bundleIdentifier), reason=\(reason)): active=\(activeText), targets=[\(targetsText)]"
        )
    }
}

#endif
