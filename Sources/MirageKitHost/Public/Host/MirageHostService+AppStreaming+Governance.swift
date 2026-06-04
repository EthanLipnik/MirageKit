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
    /// Maximum number of app-window streams that can remain visible for one app session.
    nonisolated static let appStreamMaxVisibleSlots = 8

    /// Lower bound used when normalizing an app session's shared bitrate budget.
    nonisolated static let minimumSharedBitrateBudgetBps = 1_000_000

    /// Resolves the shared app-session bitrate budget from a request or host default.
    func resolvedAppSessionBitrateBudget(requestedBitrate: Int?) -> Int? {
        let sourceBitrate = requestedBitrate ??
            encoderConfig.bitrate ??
            MirageEncoderConfiguration.highQuality.bitrate
        guard let sourceBitrate else { return nil }
        let normalized = MirageBitrateQualityMapper.normalizedTargetBitrate(bitrate: sourceBitrate) ?? sourceBitrate
        return max(Self.minimumSharedBitrateBudgetBps, normalized)
    }

    /// Sends the latest app-window inventory to a connected client.
    func sendAppWindowInventoryUpdate(bundleIdentifier: String, clientID: UUID) async {
        guard let inventory = await appStreamManager.inventoryMessage(bundleIdentifier: bundleIdentifier) else { return }
        guard let clientContext = findClientContext(clientID: clientID) else { return }
        let atlasLayouts = if let coordinator = appAtlasCoordinatorsByClientID[clientID] {
            await coordinator.atlasLayouts()
        } else {
            inventory.atlasLayouts ?? []
        }
        let slots = inventory.slots.map { slot in
            guard let layout = atlasLayouts.first(where: { $0.mediaStreamID == slot.mediaStreamID }),
                  let atlasRegion = layout.region(for: slot.window.windowID) else {
                return slot
            }
            return AppWindowInventoryMessage.Slot(
                slotIndex: slot.slotIndex,
                streamID: slot.streamID,
                mediaStreamID: slot.mediaStreamID,
                window: slot.window,
                atlasRegion: atlasRegion
            )
        }
        let outboundInventory = AppWindowInventoryMessage(
            bundleIdentifier: inventory.bundleIdentifier,
            appSessionID: inventory.appSessionID,
            maxVisibleSlots: inventory.maxVisibleSlots,
            slots: slots,
            hiddenWindows: inventory.hiddenWindows,
            atlasLayouts: atlasLayouts.isEmpty ? inventory.atlasLayouts : atlasLayouts
        )
        do {
            try await clientContext.send(.appWindowInventory, content: outboundInventory)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send app window inventory update: ")
        }
    }

    func stopAppStreamGovernorsIfIdle() async {
        let hasStreamingSessions = await appStreamManager.allSessions().contains { $0.state == .streaming }
        guard !hasStreamingSessions else { return }
        for task in appStreamPolicyTransitionTasksByBundleID.values {
            task.cancel()
        }
        appStreamPolicyTransitionTasksByBundleID.removeAll()
    }

    func refreshAppStreamGovernors(reason: String) async {
        let sessions = await appStreamManager.allSessions().filter { $0.state == .streaming }
        for session in sessions {
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: session.bundleIdentifier,
                reason: reason
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
        guard let session = await appStreamManager.sessionForStreamID(streamID) else { return }

        if forceOwnershipSwitch {
            await appStreamRuntimeOrchestrator.forceOwnership(streamID: streamID)
        }

        await recomputeAppSessionBitrateBudget(
            bundleIdentifier: session.bundleIdentifier,
            reason: "interaction:\(reason)"
        )
    }

    func clearAppStreamGovernorState(streamID: StreamID) {
        stopWindowVisibleFrameMonitor(streamID: streamID)
        pendingWindowResizeResolutionByStreamID.removeValue(forKey: streamID)
        windowResizeRequestCounterByStreamID.removeValue(forKey: streamID)
        windowResizeInFlightStreamIDs.remove(streamID)
        Task {
            await appStreamRuntimeOrchestrator.unregisterStream(streamID: streamID)
            await streamPolicyApplier.clear(streamID: streamID)
        }
    }

    func recomputeAppSessionBitrateBudget(bundleIdentifier: String, reason: String) async {
        guard let session = await appStreamManager.session(bundleIdentifier: bundleIdentifier) else {
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

        let usesSharedAppAtlas = visibleStreamIDs.contains { streamID in
            guard let windowInfo = session.windowStreams.values.first(where: { $0.streamID == streamID }) else {
                return false
            }
            return windowInfo.mediaStreamID != streamID && streamsByID[streamID] == nil
        }
        let policyBitrateBudgetBps = usesSharedAppAtlas ? nil : session.bitrateBudgetBps
        let activeTargetFPS = await resolvedActiveTargetFPS(for: visibleStreamIDs)

        let snapshot = await appStreamRuntimeOrchestrator.makeRuntimePolicySnapshot(
            bundleIdentifier: bundleIdentifier,
            visibleStreamIDs: visibleStreamIDs,
            bitrateBudgetBps: policyBitrateBudgetBps,
            activeTargetFPS: activeTargetFPS
        )
        MirageLogger.host(
            "Recomputed app stream policy bundle=\(bundleIdentifier) mode=" +
                "\(usesSharedAppAtlas ? "shared-atlas" : "dedicated-streams") " +
                "reason=\(reason) visibleStreams=[\(visibleStreamIDs.map(String.init).joined(separator: ","))] " +
                "budget=\(policyBitrateBudgetBps.map(String.init) ?? "presentation-only")"
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
            if !usesSharedAppAtlas, let bitrate = policy.targetBitrateBps {
                appliedTargets[policy.streamID] = bitrate
            }

            if isActive {
                if usesDedicatedDisplay {
                    ensureWindowVisibleFrameMonitor(streamID: policy.streamID)
                } else {
                    stopWindowVisibleFrameMonitor(streamID: policy.streamID)
                }
            } else {
                if usesDedicatedDisplay {
                    ensureWindowVisibleFrameMonitor(streamID: policy.streamID)
                } else {
                    stopWindowVisibleFrameMonitor(streamID: policy.streamID)
                }
                pendingWindowResizeResolutionByStreamID.removeValue(forKey: policy.streamID)
                windowResizeRequestCounterByStreamID.removeValue(forKey: policy.streamID)
            }

            guard !usesSharedAppAtlas,
                  let context = streamsByID[policy.streamID] else {
                continue
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
        do {
            try await clientContext.send(.streamPolicyUpdate, content: policyUpdate)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to send streamPolicyUpdate: ")
        }

        if snapshot.activeChanged,
           let activeStreamID = snapshot.activeStreamID,
           let activeSession = activeSessionByStreamID[activeStreamID] {
            activateWindow(activeSession.window)
        }

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

        let delayMilliseconds = max(1, Int((remainingSeconds * 1000).rounded(.up)))
        appStreamPolicyTransitionTasksByBundleID[key] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(delayMilliseconds))
            } catch {
                return
            }
            guard let self else { return }
            appStreamPolicyTransitionTasksByBundleID.removeValue(forKey: key)
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: key,
                reason: "demotion grace expired"
            )
        }
    }

    private func resolvedActiveTargetFPS(for streamIDs: [StreamID]) async -> Int {
        for streamID in streamIDs {
            guard let context = streamsByID[streamID] else { continue }
            let streamFPS = await context.encoderConfig.targetFrameRate
            if streamFPS >= AppStreamRuntimeOrchestrator.highRefreshActiveTargetFPS {
                return AppStreamRuntimeOrchestrator.highRefreshActiveTargetFPS
            }
        }
        return AppStreamRuntimeOrchestrator.defaultActiveTargetFPS
    }
}

#endif
