//
//  MirageHostService+AppStreaming+Governance.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App-stream inventory, host-owned activity throttling, and shared bitrate governance.
//

import Foundation
import MirageKit

#if os(macOS)

@MainActor
extension MirageHostService {
    nonisolated static let appStreamMaxVisibleSlots = 8
    nonisolated static let minimumSharedBitrateBudgetBps = 1_000_000
    nonisolated static let minimumPrioritizedWindowBitrateBps = 5_000_000
    nonisolated static let multiWindowPerStreamBitrateCapBps = 60_000_000

    func resolvedMaxVisibleAppWindowSlots(_ requestedSlots: Int) -> Int {
        max(1, min(Self.appStreamMaxVisibleSlots, requestedSlots))
    }

    nonisolated static func appStreamPerStreamBitrateCap(visibleStreamCount: Int) -> Int {
        visibleStreamCount > 1 ? multiWindowPerStreamBitrateCapBps : Int.max
    }

    func resolvedAppSessionBitrateBudget(requestedBitrate: Int?) -> Int? {
        let sourceBitrate = requestedBitrate ?? encoderConfig.bitrate ?? MirageEncoderConfiguration.highQuality.bitrate
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
        if appStreamGovernorTask != nil { return }
        let hasSessions = !(await appStreamManager.getAllSessions().isEmpty)
        guard hasSessions else { return }

        appStreamGovernorTask = Task { @MainActor [weak self] in
            await self?.runAppStreamGovernorsLoop()
        }
    }

    func stopAppStreamGovernorsIfIdle() async {
        let hasSessions = !(await appStreamManager.getAllSessions().isEmpty)
        guard !hasSessions else { return }
        appStreamGovernorTask?.cancel()
        appStreamGovernorTask = nil
    }

    private func runAppStreamGovernorsLoop() async {
        while !Task.isCancelled {
            await refreshAppStreamGovernors(reason: "tick")
            do {
                try await Task.sleep(for: appStreamGovernorTickInterval)
            } catch {
                return
            }
        }
    }

    func refreshAppStreamGovernors(reason: String) async {
        let sessions = await appStreamManager.getAllSessions()
        if sessions.isEmpty {
            appStreamGovernorTask?.cancel()
            appStreamGovernorTask = nil
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        for session in sessions where session.state == .streaming {
            let streamIDs = session.windowStreams.values.map(\.streamID)
            for streamID in streamIDs {
                await evaluateAppStreamActivity(streamID: streamID, now: now, reason: reason)
            }
            await recomputeAppSessionBitrateBudget(
                bundleIdentifier: session.bundleIdentifier,
                reason: "governor:\(reason)"
            )
        }
    }

    nonisolated func noteAppStreamInputSignal(streamID: StreamID) {
        let now = CFAbsoluteTimeGetCurrent()
        appStreamLastInputSignalByStreamID.withLock { signals in
            signals[streamID] = now
        }
        dispatchMainWork { [weak self] in
            guard let self else { return }
            await self.evaluateAppStreamActivity(streamID: streamID, now: now, reason: "input")
        }
    }

    func markAppStreamInteraction(streamID: StreamID, reason: String) async {
        let now = CFAbsoluteTimeGetCurrent()
        appStreamLastInputSignalByStreamID.withLock { signals in
            signals[streamID] = now
        }
        await evaluateAppStreamActivity(streamID: streamID, now: now, reason: reason)
    }

    func setAppStreamFrontmostSignal(streamID: StreamID, isActive: Bool, reason: String) async {
        appStreamFrontmostSignalByStreamID[streamID] = isActive
        await evaluateAppStreamActivity(
            streamID: streamID,
            now: CFAbsoluteTimeGetCurrent(),
            reason: "\(reason):frontmost=\(isActive)"
        )
    }

    func registerAppStreamDesiredFrameRate(streamID: StreamID, frameRate: Int) {
        appStreamDesiredActiveFrameRateByStreamID[streamID] = max(1, frameRate)
    }

    func clearAppStreamGovernorState(streamID: StreamID) {
        appStreamFrontmostSignalByStreamID.removeValue(forKey: streamID)
        appStreamAppliedActiveStateByStreamID.removeValue(forKey: streamID)
        appStreamDesiredActiveFrameRateByStreamID.removeValue(forKey: streamID)
        appStreamLastInputSignalByStreamID.withLock { signals in
            signals.removeValue(forKey: streamID)
        }
    }

    func refreshAppStreamActivity(streamID: StreamID, reason: String) async {
        await evaluateAppStreamActivity(
            streamID: streamID,
            now: CFAbsoluteTimeGetCurrent(),
            reason: reason
        )
    }

    private func evaluateAppStreamActivity(
        streamID: StreamID,
        now: CFAbsoluteTime,
        reason: String
    ) async {
        guard let session = await appStreamManager.getSessionForStreamID(streamID),
              session.state == .streaming,
              let context = streamsByID[streamID] else {
            clearAppStreamGovernorState(streamID: streamID)
            return
        }

        let lastInputAt = appStreamLastInputSignalByStreamID.withLock { $0[streamID] }
        let hasRecentInput: Bool = if let lastInputAt {
            (now - lastInputAt) <= appStreamInputActiveHoldSeconds
        } else {
            false
        }
        let frontmostSignal = appStreamFrontmostSignalByStreamID[streamID] ?? false
        let isActive = hasRecentInput || frontmostSignal
        let allowFrameRateThrottling = Self.shouldThrottleAppStreamFrameRate(
            maxVisibleSlots: session.maxVisibleSlots
        )
        let previousState = appStreamAppliedActiveStateByStreamID[streamID]
        await appStreamManager.markStreamActivity(
            bundleIdentifier: session.bundleIdentifier,
            streamID: streamID,
            isActive: isActive
        )

        guard previousState != isActive else { return }
        appStreamAppliedActiveStateByStreamID[streamID] = isActive

        if isActive {
            if allowFrameRateThrottling {
                let baselineDesiredRate: Int
                if let storedDesiredRate = appStreamDesiredActiveFrameRateByStreamID[streamID] {
                    baselineDesiredRate = storedDesiredRate
                } else {
                    baselineDesiredRate = await context.getTargetFrameRate()
                }
                let desiredFrameRate = max(
                    appStreamInactivityThrottleFPS + 1,
                    baselineDesiredRate
                )
                appStreamDesiredActiveFrameRateByStreamID[streamID] = desiredFrameRate
                do {
                    try await context.updateFrameRate(desiredFrameRate)
                    await context.requestKeyframe()
                    MirageLogger.host(
                        "App stream \(streamID) active via host signals (\(reason)); restored \(desiredFrameRate) fps"
                    )
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to restore app stream frame rate: ")
                }
            } else {
                MirageLogger.host(
                    "App stream \(streamID) active via host signals (\(reason)); frame-rate throttle disabled by policy"
                )
            }
        } else {
            if allowFrameRateThrottling {
                let currentFrameRate = await context.getTargetFrameRate()
                if currentFrameRate > appStreamInactivityThrottleFPS {
                    appStreamDesiredActiveFrameRateByStreamID[streamID] = currentFrameRate
                } else if appStreamDesiredActiveFrameRateByStreamID[streamID] == nil {
                    appStreamDesiredActiveFrameRateByStreamID[streamID] = 60
                }
                do {
                    try await context.updateFrameRate(appStreamInactivityThrottleFPS)
                    MirageLogger.host(
                        "App stream \(streamID) inactive via host signals (\(reason)); throttled to \(appStreamInactivityThrottleFPS) fps"
                    )
                } catch {
                    MirageLogger.error(.host, error: error, message: "Failed to throttle inactive app stream: ")
                }
            } else {
                MirageLogger.host(
                    "App stream \(streamID) inactive via host signals (\(reason)); frame-rate throttle disabled by policy"
                )
            }
        }

        await recomputeAppSessionBitrateBudget(
            bundleIdentifier: session.bundleIdentifier,
            reason: "activity:\(reason)"
        )
    }

    nonisolated static func shouldThrottleAppStreamFrameRate(maxVisibleSlots _: Int) -> Bool {
        false
    }

    func recomputeAppSessionBitrateBudget(bundleIdentifier: String, reason: String) async {
        guard let session = await appStreamManager.getSession(bundleIdentifier: bundleIdentifier) else { return }
        guard !session.windowStreams.isEmpty else {
            await appStreamManager.setStreamBitrateTargets(bundleIdentifier: bundleIdentifier, targets: [:])
            return
        }

        let previousTargets = await appStreamManager.streamBitrateTargets(bundleIdentifier: bundleIdentifier)
        let resolvedBudget = session.bitrateBudgetBps ??
            resolvedAppSessionBitrateBudget(requestedBitrate: nil) ??
            Self.minimumSharedBitrateBudgetBps
        let visibleInfos = Array(session.windowStreams.values)
        let visibleStreamIDs = visibleInfos.map(\.streamID).sorted()
        let visibleCount = max(1, visibleStreamIDs.count)
        let perStreamBitrateCap = Self.appStreamPerStreamBitrateCap(visibleStreamCount: visibleCount)
        var targets: [StreamID: Int] = [:]
        switch session.bitrateAllocationPolicy {
        case .splitEvenly:
            let perStreamShare = resolvedBudget / visibleCount
            var remainingBudget = max(0, resolvedBudget - (perStreamShare * visibleCount))
            for streamID in visibleStreamIDs {
                targets[streamID] = perStreamShare
                if remainingBudget > 0 {
                    targets[streamID, default: 0] += 1
                    remainingBudget -= 1
                }
            }
        case .prioritizeActiveWindow:
            let maxSafeFloorPerStream = max(1, resolvedBudget / visibleCount)
            let floorSharePerStream = min(
                maxSafeFloorPerStream,
                max(Self.minimumPrioritizedWindowBitrateBps, resolvedBudget / max(visibleCount * 20, 1))
            )
            for streamID in visibleStreamIDs {
                targets[streamID] = floorSharePerStream
            }

            let activityMap = session.streamActivityByStreamID
            let priorityStreamIDs = prioritizedAllocationStreamIDs(
                visibleStreamIDs: visibleStreamIDs,
                activityMap: activityMap,
                previousTargets: previousTargets
            )
            let floorTotal = floorSharePerStream * visibleCount
            var remainingBudget = max(0, resolvedBudget - floorTotal)
            if !priorityStreamIDs.isEmpty, remainingBudget > 0 {
                let perStreamIncrement = remainingBudget / priorityStreamIDs.count
                remainingBudget -= perStreamIncrement * priorityStreamIDs.count
                for streamID in priorityStreamIDs {
                    targets[streamID, default: floorSharePerStream] += perStreamIncrement
                }
                if remainingBudget > 0 {
                    for streamID in priorityStreamIDs where remainingBudget > 0 {
                        targets[streamID, default: floorSharePerStream] += 1
                        remainingBudget -= 1
                    }
                }
            }
        }

        if perStreamBitrateCap < Int.max {
            for streamID in visibleStreamIDs {
                guard let targetBitrate = targets[streamID] else { continue }
                targets[streamID] = min(targetBitrate, perStreamBitrateCap)
            }
        }

        if previousTargets == targets { return }

        for streamID in visibleStreamIDs {
            guard let context = streamsByID[streamID],
                  let targetBitrate = targets[streamID] else { continue }
            do {
                try await context.updateEncoderSettings(
                    bitDepth: nil,
                    bitrate: targetBitrate
                )
            } catch {
                MirageLogger.error(
                    .host,
                    error: error,
                    message: "Failed to apply shared bitrate target for stream \(streamID): "
                )
            }
        }

        await appStreamManager.setStreamBitrateTargets(bundleIdentifier: bundleIdentifier, targets: targets)
        let renderedTargets = visibleStreamIDs.map { streamID in
            "\(streamID)=\(targets[streamID] ?? 0)"
        }.joined(separator: ", ")
        MirageLogger.host(
            "Shared bitrate governor update (\(bundleIdentifier), reason=\(reason)): budget=\(resolvedBudget), targets=[\(renderedTargets)]"
        )
    }

    private func prioritizedAllocationStreamIDs(
        visibleStreamIDs: [StreamID],
        activityMap: [StreamID: Bool],
        previousTargets: [StreamID: Int]
    ) -> [StreamID] {
        guard !visibleStreamIDs.isEmpty else { return [] }

        let activeStreamIDs = visibleStreamIDs.filter { activityMap[$0] ?? false }
        let candidateStreamIDs = activeStreamIDs.isEmpty ? visibleStreamIDs : activeStreamIDs
        if let stickyStreamID = stickyPrioritizedStreamID(
            candidateStreamIDs: candidateStreamIDs,
            previousTargets: previousTargets
        ) {
            return [stickyStreamID]
        }
        guard let preferredStreamID = preferredStreamIDForPriority(candidateStreamIDs) else { return [] }
        return [preferredStreamID]
    }

    private func stickyPrioritizedStreamID(
        candidateStreamIDs: [StreamID],
        previousTargets: [StreamID: Int]
    ) -> StreamID? {
        guard candidateStreamIDs.count > 1 else { return candidateStreamIDs.first }

        var bestStreamID: StreamID?
        var bestTarget = Int.min
        var isTied = false

        for streamID in candidateStreamIDs {
            let target = previousTargets[streamID] ?? Int.min
            if target > bestTarget {
                bestTarget = target
                bestStreamID = streamID
                isTied = false
            } else if target == bestTarget {
                isTied = true
            }
        }

        guard bestTarget != Int.min, !isTied else { return nil }
        return bestStreamID
    }

    private func preferredStreamIDForPriority(_ streamIDs: [StreamID]) -> StreamID? {
        guard !streamIDs.isEmpty else { return nil }
        let lastInputSnapshot = appStreamLastInputSignalByStreamID.withLock { $0 }
        return streamIDs.sorted { lhs, rhs in
            let lhsFrontmost = appStreamFrontmostSignalByStreamID[lhs] ?? false
            let rhsFrontmost = appStreamFrontmostSignalByStreamID[rhs] ?? false
            if lhsFrontmost != rhsFrontmost {
                return lhsFrontmost && !rhsFrontmost
            }
            let lhsLastInput = lastInputSnapshot[lhs] ?? 0
            let rhsLastInput = lastInputSnapshot[rhs] ?? 0
            if lhsLastInput != rhsLastInput {
                return lhsLastInput > rhsLastInput
            }
            return lhs < rhs
        }.first
    }
}

#endif
