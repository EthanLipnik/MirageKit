//
//  MirageClientService+ControlPath.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Client control-path telemetry and history.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    nonisolated private static let controlPathHistoryLimit = 8

    // MARK: - Control Path Handling

    /// Stores the latest control path and records path switches.
    func handleControlPathUpdate(_ snapshot: MirageNetworkPathSnapshot) {
        let previous = controlPathSnapshot
        controlPathSnapshot = snapshot
        currentControlPathKind = snapshot.kind
        currentControlPathStatus = MirageClientNetworkPathStatus(snapshot: snapshot)
        recordControlPathHistory(snapshot)
        if previous?.kind != snapshot.kind || previous?.mediaProfile != snapshot.mediaProfile {
            refreshActiveStreamTransportProfiles(for: snapshot)
        }
        guard let previous, previous.signature != snapshot.signature else { return }
        if previous.kind != snapshot.kind || previous.mediaProfile != snapshot.mediaProfile {
            awdlPathSwitches &+= 1
            MirageLogger.client(
                "Control path switch \(previous.kind.rawValue)/\(previous.mediaProfile.rawValue) -> " +
                    "\(snapshot.kind.rawValue)/\(snapshot.mediaProfile.rawValue) (count \(awdlPathSwitches))"
            )
        }
    }

    /// Emits throttled AWDL radio metrics while an AWDL media path is active.
    func logAwdlRadioTelemetryIfNeeded(
        streamID: StreamID? = nil,
        metrics: StreamController.ClientFrameMetrics? = nil
    ) {
        guard currentMediaPathUsesAwdlRadioPolicy else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAwdlTelemetryLogTime == 0 || now - lastAwdlTelemetryLogTime >= 1.0 else { return }
        lastAwdlTelemetryLogTime = now
        let path = controlPathSnapshot?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue
        let media = controlPathSnapshot?.mediaProfile.rawValue ?? MirageMediaPathProfile.unknown.rawValue
        if let metrics {
            let streamText = streamID.map { "\($0)" } ?? "-"
            let hostSnapshot = streamID.flatMap { metricsStore.snapshot(for: $0) }
            let targetFPS = max(1, hostSnapshot?.hostTargetFrameRate ?? 60)
            let targetQueueFrames = Self.awdlPresentationTargetFrames(
                targetFPS: targetFPS,
                targetDelayMs: metrics.smoothestTargetDelayMs
            )
            let queueBacklogFrames = max(0, metrics.pendingFrameCount - targetQueueFrames)
            let targetFillDeficitFrames = max(0, targetQueueFrames - metrics.pendingFrameCount)
            let trueUnderfillFrames = Self.awdlPresentationUnderfillFrames(
                targetQueueFrames: targetQueueFrames,
                pendingFrameCount: metrics.pendingFrameCount,
                presentationStallCount: metrics.presentationStallCount,
                displayTickNoFrameCount: metrics.displayTickNoFrameCount,
                pendingFrameNotReadyDisplayTickCount: metrics.pendingFrameNotReadyDisplayTickCount
            )
            let hostActualBitrate = hostSnapshot?.hostEncoderActualBitrateBps ??
                hostSnapshot?.hostCurrentBitrate ??
                hostSnapshot?.hostEncoderRequestedBitrateBps
            MirageLogger.client(
                "AWDL client telemetry: stream=\(streamText) " +
                    "path=\(path) media=\(media) " +
                    "hostEncoded=\(formatAwdlResolution(hostSnapshot)) " +
                    "hostFPS=\(targetFPS) " +
                    "hostBitrateMbps=\(formatAwdlBitrate(hostActualBitrate)) " +
                    "hostQuality=\(formatAwdlOptionalMetric(hostSnapshot?.hostActiveQuality)) " +
                    "hostScale=\(formatAwdlOptionalMetric(hostSnapshot?.hostEffectiveStreamScale)) " +
                    "hostPressure=\(hostSnapshot?.hostRealtimePressureState ?? "-") " +
                    "hostReason=\(hostSnapshot?.hostRealtimePressureReason ?? "-") " +
                    "hostAwdlState=\(hostSnapshot?.hostAwdlPolicyState ?? "-") " +
                    "hostAwdlTrigger=\(hostSnapshot?.hostAwdlPolicyTrigger ?? "-") " +
                    "hostAwdlLever=\(hostSnapshot?.hostAwdlSelectedLever ?? "-") " +
                    "hostAwdlPlayoutMs=\(formatAwdlOptionalMetric(hostSnapshot?.hostAwdlPlayoutDelayMs)) " +
                    "hostAwdlScale=\(formatAwdlOptionalMetric(hostSnapshot?.hostAwdlResolutionScale)) " +
                    "hostAwdlQualityCuts=\(formatAwdlOptionalBool(hostSnapshot?.hostAwdlQualityReductionAllowed)) " +
                    "hostAwdlPacingMbps=\(formatAwdlBitrate(hostSnapshot?.hostAwdlPacingBudgetBps)) " +
                    "hostSendProfile=\(hostSnapshot?.hostMediaSendProfile ?? "-") " +
                    "hostQueueBytes=\(formatAwdlOptionalInteger(hostSnapshot?.hostSendQueueBytes)) " +
                    "hostPacerSleepMs=\(formatAwdlOptionalMetric(hostSnapshot?.hostPacketPacerAverageSleepMs)) " +
                    "hostDeadlineDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostSenderLocalDeadlineDrops)) " +
                    "hostStaleDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostStalePacketDrops)) " +
                    "hostHoldDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostNonKeyframeHoldDrops)) " +
                    "loomQueuedDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableDropCount)) " +
                    "loomDeadlineDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableDeadlineExpiredDrops)) " +
                    "loomQueueDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableQueueLimitDrops)) " +
                    "loomSupersededDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableSupersededDrops)) " +
                    "loomUnsupportedTransportDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableUnsupportedTransportDrops)) " +
                    "loomClosedDrops=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableClosedDrops)) " +
                    "loomPending=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliablePendingPackets)) " +
                    "loomOutstanding=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableOutstandingPackets)) " +
                    "loomQueuedBytes=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableQueuedBytes)) " +
                    "loomQueuedBytesMax=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableQueuedBytesMax)) " +
                    "loomEnq=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableEnqueuedCount)) " +
                    "loomSent=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableSentCount)) " +
                    "loomDone=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableCompletedCount)) " +
                    "loomErr=\(formatAwdlOptionalInteger(hostSnapshot?.hostQueuedUnreliableErrorCount)) " +
                    "loomDwellP99Ms=\(formatAwdlOptionalMetric(hostSnapshot?.hostQueuedUnreliableQueueDwellP99Ms)) " +
                    "loomSendGapP99Ms=\(formatAwdlOptionalMetric(hostSnapshot?.hostQueuedUnreliableSendGapP99Ms)) " +
                    "loomContentP99Ms=\(formatAwdlOptionalMetric(hostSnapshot?.hostQueuedUnreliableContentProcessedP99Ms)) " +
                    "rxFPS=\(formatAwdlMetric(metrics.receivedFPS)) " +
                    "decodeFPS=\(formatAwdlMetric(metrics.decodedFPS)) " +
                    "decodeSubmissions=\(metrics.inFlightDecodeSubmissions)/\(metrics.decodeSubmissionLimit) " +
                    "presentFPS=\(formatAwdlMetric(metrics.visibleFrameFPS)) " +
                    "rxGapMaxMs=\(formatAwdlMetric(metrics.receivedWorstGapMs)) " +
                    "rxP99Ms=\(formatAwdlMetric(metrics.receivedFrameIntervalP99Ms)) " +
                    "ingressJitterP99Ms=\(formatAwdlMetric(metrics.receiverIngressJitterP99Ms)) " +
                    "frameP95Ms=\(formatAwdlMetric(metrics.reassemblerFrameCompletionLatencyP95Ms)) " +
                    "keyframeP95Ms=\(formatAwdlMetric(metrics.reassemblerKeyframeCompletionLatencyP95Ms)) " +
                    "pFrameP50Ms=\(formatAwdlMetric(metrics.reassemblerPFrameCompletionLatencyP50Ms)) " +
                    "pFrameP95Ms=\(formatAwdlMetric(metrics.reassemblerPFrameCompletionLatencyP95Ms)) " +
                    "latePFrames=\(metrics.reassemblerLatePFrameCompletionCount) " +
                    "reassemblyFrames=\(metrics.reassemblerPendingFrameCount) " +
                    "keyframes=\(metrics.reassemblerPendingKeyframeCount) " +
                    "missingFragments=\(metrics.reassemblerMissingFragmentTimeouts) " +
                    "fecRecovered=\(metrics.reassemblerFECRecoveredFragmentCount) " +
                    "forwardGaps=\(metrics.reassemblerForwardGapTimeouts) " +
                    "playoutTargetMs=\(formatAwdlMetric(metrics.smoothestTargetDelayMs)) " +
                    "playoutFrames=\(metrics.playoutDelayFrames) " +
                    "queueFrames=\(metrics.pendingFrameCount) " +
                    "targetQueueFrames=\(targetQueueFrames) " +
                    "backlogFrames=\(queueBacklogFrames) " +
                    "targetFillDeficitFrames=\(targetFillDeficitFrames) " +
                    "underfillFrames=\(trueUnderfillFrames) " +
                    "presentGapMaxMs=\(formatAwdlMetric(metrics.worstPresentationGapMs)) " +
                    "underflows=\(metrics.displayTickNoFrameCount) " +
                    "pendingNotReadyTicks=\(metrics.pendingFrameNotReadyDisplayTickCount) " +
                    "presentationStalls=\(metrics.presentationStallCount) " +
                    "queueDrops=\(metrics.smoothestQueueDrops) " +
                    "decodeHealthy=\(metrics.decodeHealthy) " +
                    "stalls=\(stallEvents) pathSwitches=\(awdlPathSwitches) " +
                    "hostRefreshReq=\(transportRefreshRequests)"
            )
        } else {
            MirageLogger.client(
                "AWDL client telemetry: path=\(path) media=\(media) " +
                    "stalls=\(stallEvents) pathSwitches=\(awdlPathSwitches) " +
                    "hostRefreshReq=\(transportRefreshRequests)"
            )
        }
    }

    private static func awdlPresentationTargetFrames(targetFPS: Int, targetDelayMs: Double) -> Int {
        guard targetDelayMs > 0 else { return 0 }
        let frameBudgetMs = 1_000.0 / Double(max(1, targetFPS))
        return max(1, Int((targetDelayMs / frameBudgetMs).rounded(.up)))
    }

    private static func awdlPresentationUnderfillFrames(
        targetQueueFrames: Int,
        pendingFrameCount: Int,
        presentationStallCount: UInt64,
        displayTickNoFrameCount: UInt64,
        pendingFrameNotReadyDisplayTickCount: UInt64
    ) -> Int {
        guard presentationStallCount > 0 ||
            displayTickNoFrameCount > 0 ||
            pendingFrameNotReadyDisplayTickCount > 0 else {
            return 0
        }
        return max(0, targetQueueFrames - pendingFrameCount)
    }

    private func formatAwdlMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }

    private func formatAwdlOptionalMetric(_ value: Double?) -> String {
        guard let value else { return "-" }
        return formatAwdlMetric(value)
    }

    private func formatAwdlBitrate(_ bitrate: Int?) -> String {
        guard let bitrate, bitrate > 0 else { return "-" }
        return String(format: "%.1f", Double(bitrate) / 1_000_000.0)
    }

    private func formatAwdlOptionalBool(_ value: Bool?) -> String {
        guard let value else { return "-" }
        return value ? "true" : "false"
    }

    private func formatAwdlOptionalInteger<T: BinaryInteger>(_ value: T?) -> String {
        guard let value else { return "-" }
        return "\(value)"
    }

    private func formatAwdlResolution(_ snapshot: MirageClientMetricsSnapshot?) -> String {
        guard let width = snapshot?.hostEncodedWidth,
              let height = snapshot?.hostEncodedHeight,
              width > 0,
              height > 0 else {
            return "-"
        }
        return "\(width)x\(height)"
    }

    /// Clears the bounded control-path history after disconnect or connection reset.
    func resetControlPathHistory() {
        controlPathHistory.removeAll(keepingCapacity: false)
    }

    /// Clears the current control path and any history derived from it.
    func clearControlPathState() {
        controlPathSnapshot = nil
        currentControlPathKind = nil
        currentControlPathStatus = nil
        streamingPolicyPathKindOverride = nil
        streamingPolicyMediaPathProfileOverride = nil
        resetControlPathHistory()
    }

    /// Overrides the stream policy path used for host budgeting while keeping raw path observations separate.
    public func setStreamingPolicyPathKindOverride(_ pathKind: MirageNetworkPathKind?) {
        streamingPolicyPathKindOverride = pathKind
        streamingPolicyMediaPathProfileOverride = pathKind.map {
            MirageMediaPathProfile.classify(
                pathKind: $0,
                interfaceNames: controlPathSnapshot?.interfaceNames ?? [],
                usesWiFi: controlPathSnapshot?.usesWiFi ?? false,
                usesWired: controlPathSnapshot?.usesWired ?? false,
                usesCellular: controlPathSnapshot?.usesCellular ?? false,
                usesLoopback: controlPathSnapshot?.usesLoopback ?? false,
                usesOther: controlPathSnapshot?.usesOther ?? false
            )
        }
    }

    func suppressCurrentAwdlProximityRouteIfNeeded(
        duration: TimeInterval = 15 * 60,
        reason: String
    ) {
        guard let connectedHost,
              let pathStatus = currentControlPathStatus,
              Self.pathStatusIndicatesAwdl(pathStatus) else {
            return
        }

        suppressAwdlProximityRoute(
            for: connectedHost,
            interfaceNames: Self.awdlInterfaceNames(from: pathStatus),
            duration: duration,
            reason: reason
        )
    }

    func effectiveLatencyModeForCurrentMediaPath(_ latencyMode: MirageStreamLatencyMode?) -> MirageStreamLatencyMode? {
        guard currentMediaPathUsesAwdlRadioPolicy,
              let mediaPathProfile = effectiveMediaPathProfileForCurrentPath else {
            return latencyMode
        }
        return MirageAwdlMediaController.fixedLatencyMode(
            requestedLatencyMode: latencyMode ?? .lowestLatency,
            mediaPathProfile: mediaPathProfile
        )
    }

    func effectiveHostBufferingPolicyForCurrentMediaPath(
        _ policy: MirageHostBufferingPolicy?
    ) -> MirageHostBufferingPolicy? {
        guard currentMediaPathUsesAwdlRadioPolicy else {
            return policy
        }
        return .stability
    }

    func effectiveLowLatencyHighResolutionCompressionBoostForCurrentMediaPath(
        _ enabled: Bool?
    ) -> Bool? {
        guard currentMediaPathUsesAwdlRadioPolicy, enabled == true else {
            return enabled
        }
        return false
    }

    func effectiveFrameRateForCurrentMediaPath(_ requestedFrameRate: Int) -> Int {
        guard let mediaPathProfile = effectiveMediaPathProfileForCurrentPath else {
            return max(1, requestedFrameRate)
        }
        return MirageAwdlMediaController.fixedDisplayTargetFrameRate(
            requestedFrameRate: requestedFrameRate,
            mediaPathProfile: mediaPathProfile
        )
    }

    func applyCurrentClientPathFields(to request: inout StartDesktopStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
        request.clientPolicyPathKind = streamingPolicyPathKindOverride
        request.clientPolicyMediaPathProfile = streamingPolicyMediaPathProfileOverride
    }

    func applyCurrentClientPathFields(to request: inout StartStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
        request.clientPolicyPathKind = streamingPolicyPathKindOverride
        request.clientPolicyMediaPathProfile = streamingPolicyMediaPathProfileOverride
    }

    func applyCurrentClientPathFields(to request: inout SelectAppMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
        request.clientPolicyPathKind = streamingPolicyPathKindOverride
        request.clientPolicyMediaPathProfile = streamingPolicyMediaPathProfileOverride
    }

    func applyCurrentClientPathFields(to request: inout StartCustomStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
        request.clientPolicyPathKind = streamingPolicyPathKindOverride
        request.clientPolicyMediaPathProfile = streamingPolicyMediaPathProfileOverride
    }

    /// Appends a distinct control-path status sample, keeping only the most recent entries.
    func recordControlPathHistory(
        _ snapshot: MirageNetworkPathSnapshot,
        observedAt: Date = Date()
    ) {
        let status = MirageClientNetworkPathStatus(snapshot: snapshot)
        guard controlPathHistory.last?.status != status else { return }

        controlPathHistory.append(
            MirageClientNetworkPathHistoryEntry(
                observedAt: observedAt,
                status: status
            )
        )
        if controlPathHistory.count > Self.controlPathHistoryLimit {
            controlPathHistory.removeFirst(controlPathHistory.count - Self.controlPathHistoryLimit)
        }
    }

    /// Reapplies transport-sensitive stream pacing after the control path changes.
    private func refreshActiveStreamTransportProfiles(for snapshot: MirageNetworkPathSnapshot) {
        for (streamID, controller) in controllersByStream {
            let requestedLatencyMode = renderLatencyModeByStream[streamID] ?? .lowestLatency
            let latencyMode = effectiveLatencyModeForCurrentMediaPath(requestedLatencyMode) ?? requestedLatencyMode
            let targetFrameRate = resolvedStreamCadenceFrameRate(for: streamID)
            let playoutDelayFrames = resolvedStreamPlayoutDelayFrames(for: latencyMode)
            MirageRenderStreamStore.shared.setTransportPathKind(for: streamID, pathKind: snapshot.kind)
            MirageRenderStreamStore.shared.setMediaPathProfile(for: streamID, profile: snapshot.mediaProfile)
            MirageRenderStreamStore.shared.setLatencyMode(
                for: streamID,
                latencyMode: latencyMode,
                playoutDelayFrames: playoutDelayFrames
            )
            Task {
                await controller.setTransportPathKind(snapshot.kind)
                await controller.setMediaPathProfile(snapshot.mediaProfile)
                await controller.updateCadenceTarget(
                    sourceFPS: targetFrameRate,
                    displayFPS: targetFrameRate,
                    latencyMode: latencyMode,
                    playoutDelayFrames: playoutDelayFrames,
                    reason: "control path update"
                )
            }
        }
    }

    private static func pathStatusIndicatesAwdl(_ status: MirageClientNetworkPathStatus) -> Bool {
        if status.usesFixedRealtimeDisplayPolicy { return true }
        return !awdlInterfaceNames(from: status).isEmpty
    }

    private static func awdlInterfaceNames(from status: MirageClientNetworkPathStatus) -> [String] {
        status.interfaceNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter(isAwdlRadioInterfaceName)
    }

    private static func isAwdlRadioInterfaceName(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("awdl")
    }

    var currentMediaPathUsesAwdlRadioPolicy: Bool {
        guard let snapshot = controlPathSnapshot else { return false }
        return MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: snapshot.kind,
            mediaPathProfile: snapshot.mediaProfile,
            interfaceNames: snapshot.interfaceNames
        ).usesAwdlRadioPolicy
    }

    var effectiveMediaPathProfileForCurrentPath: MirageMediaPathProfile? {
        guard let snapshot = controlPathSnapshot else { return nil }
        return MirageMediaPathProfile.resolveRealtimeProfile(
            pathKind: snapshot.kind,
            mediaPathProfile: snapshot.mediaProfile,
            interfaceNames: snapshot.interfaceNames
        )
    }
}
