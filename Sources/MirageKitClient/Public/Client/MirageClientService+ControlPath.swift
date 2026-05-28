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

    /// Emits throttled AWDL radio metrics when steady-state diagnostics are enabled.
    func logAwdlRadioTelemetryIfNeeded(
        streamID: StreamID? = nil,
        metrics: StreamController.ClientFrameMetrics? = nil
    ) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
        guard controlPathSnapshot?.mediaProfile.usesAwdlRadioPolicy == true else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard lastAwdlTelemetryLogTime == 0 || now - lastAwdlTelemetryLogTime >= 5.0 else { return }
        lastAwdlTelemetryLogTime = now
        let path = controlPathSnapshot?.kind.rawValue ?? MirageNetworkPathKind.unknown.rawValue
        let media = controlPathSnapshot?.mediaProfile.rawValue ?? MirageMediaPathProfile.unknown.rawValue
        if let metrics {
            let streamText = streamID.map { "\($0)" } ?? "-"
            MirageLogger.metrics(
                "AWDL client telemetry: stream=\(streamText) " +
                    "path=\(path) media=\(media) " +
                    "rxFPS=\(formatAwdlMetric(metrics.receivedFPS)) " +
                    "decodeFPS=\(formatAwdlMetric(metrics.decodedFPS)) " +
                    "presentFPS=\(formatAwdlMetric(metrics.visibleFrameFPS)) " +
                    "rxGapMaxMs=\(formatAwdlMetric(metrics.receivedWorstGapMs)) " +
                    "rxP99Ms=\(formatAwdlMetric(metrics.receivedFrameIntervalP99Ms)) " +
                    "pFrameP95Ms=\(formatAwdlMetric(metrics.reassemblerPFrameCompletionLatencyP95Ms)) " +
                    "latePFrames=\(metrics.reassemblerLatePFrameCompletionCount) " +
                    "reassemblyFrames=\(metrics.reassemblerPendingFrameCount) " +
                    "keyframes=\(metrics.reassemblerPendingKeyframeCount) " +
                    "missingFragments=\(metrics.reassemblerMissingFragmentTimeouts) " +
                    "fecRecovered=\(metrics.reassemblerFECRecoveredFragmentCount) " +
                    "forwardGaps=\(metrics.reassemblerForwardGapTimeouts) " +
                    "playoutTargetMs=\(formatAwdlMetric(metrics.smoothestTargetDelayMs)) " +
                    "playoutFrames=\(metrics.playoutDelayFrames) " +
                    "presentGapMaxMs=\(formatAwdlMetric(metrics.worstPresentationGapMs)) " +
                    "underflows=\(metrics.displayTickNoFrameCount) " +
                    "presentationStalls=\(metrics.presentationStallCount) " +
                    "queueDrops=\(metrics.smoothestQueueDrops) " +
                    "decodeHealthy=\(metrics.decodeHealthy) " +
                    "activeJitterHoldMs=\(activeJitterHoldMs) " +
                    "stalls=\(stallEvents) pathSwitches=\(awdlPathSwitches) " +
                    "hostRefreshReq=\(transportRefreshRequests)"
            )
        } else {
            MirageLogger.metrics(
                "AWDL client telemetry: path=\(path) media=\(media) " +
                    "stalls=\(stallEvents) pathSwitches=\(awdlPathSwitches) " +
                    "hostRefreshReq=\(transportRefreshRequests) activeJitterHoldMs=\(activeJitterHoldMs)"
            )
        }
    }

    private func formatAwdlMetric(_ value: Double) -> String {
        String(format: "%.1f", max(0, value))
    }

    /// Clears the bounded control-path history after disconnect or connection reset.
    func resetControlPathHistory() {
        controlPathHistory.removeAll(keepingCapacity: false)
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
        guard let mediaPathProfile = controlPathSnapshot?.mediaProfile,
              mediaPathProfile.usesAwdlRadioPolicy else {
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
        guard controlPathSnapshot?.mediaProfile.usesAwdlRadioPolicy == true else {
            return policy
        }
        return .freshestFrame
    }

    func applyCurrentClientPathFields(to request: inout StartDesktopStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
    }

    func applyCurrentClientPathFields(to request: inout StartStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
    }

    func applyCurrentClientPathFields(to request: inout SelectAppMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
    }

    func applyCurrentClientPathFields(to request: inout StartCustomStreamMessage) {
        request.clientTransportPathKind = controlPathSnapshot?.kind
        request.clientMediaPathProfile = controlPathSnapshot?.mediaProfile
        request.clientPathSignature = controlPathSnapshot?.signature
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
            .filter { $0.hasPrefix("awdl") }
    }
}
