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
        let hasStreamingSessions = await appStreamManager.getAllSessions().contains { $0.state == .streaming }
        guard !hasStreamingSessions else { return }
        cancelAllScheduledAppStreamPolicyTransitions()
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
        guard AppStreamRuntimeOrchestrator.isOwnershipSwitchSignal(event) else { return }
        if case .windowFocus = event {
            await appStreamRuntimeOrchestrator.forceOwnership(streamID: streamID)
            await markAppStreamInteraction(
                streamID: streamID,
                reason: reason,
                forceOwnershipSwitch: false
            )
            return
        }
        guard isHostKeyWindowEligibleForOwnershipSwitch() else { return }
        let shouldSwitch = await appStreamRuntimeOrchestrator.requestOwnershipSwitch(streamID: streamID)
        guard shouldSwitch else { return }

        await markAppStreamInteraction(
            streamID: streamID,
            reason: reason,
            forceOwnershipSwitch: false
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
            await appStreamRuntimeOrchestrator.forceOwnership(streamID: streamID)
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
        // Runtime keeps fixed host-authoritative policy targets.
    }

    func clearAppStreamGovernorState(streamID: StreamID) {
        stopWindowVisibleFrameMonitor(streamID: streamID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
        windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
        windowResizeInFlightStreamIDs.remove(streamID)
        Task {
            await appStreamRuntimeOrchestrator.unregisterStream(streamID: streamID)
            await appStreamDisplayAllocator.unbind(streamID: streamID)
            await streamPolicyApplier.clear(streamID: streamID)
            transportRegistry.setVideoStreamActive(streamID: streamID, isActive: false)
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
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else {
            cancelScheduledAppStreamPolicyTransition(bundleIdentifier: bundleIdentifier)
            return
        }
        guard let clientContext = findClientContext(clientID: session.clientID) else {
            cancelScheduledAppStreamPolicyTransition(bundleIdentifier: bundleIdentifier)
            return
        }

        let visibleStreamIDs = session.windowStreams
            .values
            .map(\.streamID)
            .sorted()

        guard !visibleStreamIDs.isEmpty else {
            cancelScheduledAppStreamPolicyTransition(bundleIdentifier: bundleIdentifier)
            await appStreamManager.setStreamBitrateTargets(bundleIdentifier: bundleIdentifier, targets: [:])
            return
        }

        for streamID in visibleStreamIDs {
            await appStreamRuntimeOrchestrator.registerStream(
                bundleIdentifier: bundleIdentifier,
                streamID: streamID
            )
        }

        let activeTargetFPS = await resolvedActiveTargetFPS(for: visibleStreamIDs)
        let resolvedBudget = session.bitrateBudgetBps ??
            resolvedAppSessionBitrateBudget(requestedBitrate: nil)

        let snapshot = await appStreamRuntimeOrchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: bundleIdentifier,
            visibleStreamIDs: visibleStreamIDs,
            bitrateBudgetBps: resolvedBudget,
            activeTargetFPS: activeTargetFPS
        )
        scheduleAppStreamPolicyTransition(
            bundleIdentifier: bundleIdentifier,
            nextTransitionAt: snapshot.nextPolicyTransitionAt
        )

        var appliedTargets: [StreamID: Int] = [:]
        for policy in snapshot.policies {
            let isActive = policy.tier == .activeLive
            let usesDedicatedDisplay = isStreamUsingVirtualDisplay(streamID: policy.streamID)

            await appStreamManager.markStreamActivity(
                bundleIdentifier: bundleIdentifier,
                streamID: policy.streamID,
                isActive: isActive
            )
            transportRegistry.setVideoStreamActive(streamID: policy.streamID, isActive: isActive)

            if let bitrate = policy.targetBitrateBps {
                appliedTargets[policy.streamID] = bitrate
            }

            guard let context = streamsByID[policy.streamID] else { continue }
            if isActive {
                if usesDedicatedDisplay {
                    ensureWindowVisibleFrameMonitor(streamID: policy.streamID)
                } else {
                    stopWindowVisibleFrameMonitor(streamID: policy.streamID)
                }
                await appStreamDisplayAllocator.bindLive(streamID: policy.streamID)
            } else {
                if usesDedicatedDisplay {
                    ensureWindowVisibleFrameMonitor(streamID: policy.streamID)
                } else {
                    stopWindowVisibleFrameMonitor(streamID: policy.streamID)
                }
                pendingWindowResizeResolutionByStreamID.removeValue(forKey: policy.streamID)
                windowResizeRequestCounterByStreamID.removeValue(forKey: policy.streamID)
                await appStreamDisplayAllocator.bindSnapshot(streamID: policy.streamID)
            }

            await streamPolicyApplier.apply(
                policy: policy,
                context: context,
                requestRecoveryKeyframe: snapshot.activeChanged && snapshot.activeStreamID == policy.streamID
            )
        }

        await appStreamManager.setStreamBitrateTargets(
            bundleIdentifier: bundleIdentifier,
            targets: appliedTargets
        )
        let policyUpdate = StreamPolicyUpdateMessage(epoch: snapshot.epoch, policies: snapshot.policies)
        try? await clientContext.send(.streamPolicyUpdate, content: policyUpdate)

        let activeText = snapshot.activeStreamID.map(String.init) ?? "none"
        let targetsText = snapshot.policies.map { policy in
            let bitrate = policy.targetBitrateBps.map(String.init) ?? "auto"
            return "\(policy.streamID)=\(policy.tier.rawValue):\(policy.targetFPS)fps@\(bitrate)"
        }.joined(separator: ", ")

        MirageLogger.host(
            "App-stream runtime update (\(bundleIdentifier), reason=\(reason), epoch=\(snapshot.epoch)): active=\(activeText), targets=[\(targetsText)]"
        )
    }

    private func cancelScheduledAppStreamPolicyTransition(bundleIdentifier: String) {
        let key = bundleIdentifier.lowercased()
        appStreamPolicyTransitionTasksByBundleID.removeValue(forKey: key)?.cancel()
    }

    private func cancelAllScheduledAppStreamPolicyTransitions() {
        for task in appStreamPolicyTransitionTasksByBundleID.values {
            task.cancel()
        }
        appStreamPolicyTransitionTasksByBundleID.removeAll()
    }

    private func scheduleAppStreamPolicyTransition(
        bundleIdentifier: String,
        nextTransitionAt: CFAbsoluteTime?
    ) {
        cancelScheduledAppStreamPolicyTransition(bundleIdentifier: bundleIdentifier)
        guard let nextTransitionAt else { return }

        let key = bundleIdentifier.lowercased()
        let now = CFAbsoluteTimeGetCurrent()
        let remainingSeconds = nextTransitionAt - now

        if remainingSeconds <= 0 {
            Task { @MainActor [weak self] in
                await self?.recomputeAppSessionBitrateBudget(
                    bundleIdentifier: key,
                    reason: "demotion grace expired"
                )
            }
            return
        }

        let delayMilliseconds = max(1, Int((remainingSeconds * 1_000).rounded(.up)))
        appStreamPolicyTransitionTasksByBundleID[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self else { return }
            self.appStreamPolicyTransitionTasksByBundleID.removeValue(forKey: key)
            await self.recomputeAppSessionBitrateBudget(
                bundleIdentifier: key,
                reason: "demotion grace expired"
            )
        }
    }

    private func resolvedActiveTargetFPS(for streamIDs: [StreamID]) async -> Int {
        for streamID in streamIDs {
            guard let context = streamsByID[streamID] else { continue }
            let streamFPS = await context.getTargetFrameRate()
            if streamFPS >= AppStreamRuntimeOrchestrator.highRefreshActiveTargetFPS {
                return AppStreamRuntimeOrchestrator.highRefreshActiveTargetFPS
            }
        }
        return AppStreamRuntimeOrchestrator.defaultActiveTargetFPS
    }
}

#endif
