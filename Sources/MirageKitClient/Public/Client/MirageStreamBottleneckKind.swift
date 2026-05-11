//
//  MirageStreamBottleneckKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

import Foundation

public enum MirageStreamBottleneckKind: String, Sendable, Equatable {
    case captureBound
    case encodeBound
    case hostCadenceLimited
    case networkBound
    case decodeBound
    case presentationBound
    case mixed
    case unknown

    public var displayName: String {
        switch self {
        case .captureBound:
            "Capture-bound"
        case .encodeBound:
            "Encode-bound"
        case .hostCadenceLimited:
            "Host source limited"
        case .networkBound:
            "Network-bound"
        case .decodeBound:
            "Decode-bound"
        case .presentationBound:
            "Presentation-bound"
        case .mixed:
            "Mixed"
        case .unknown:
            "Unknown"
        }
    }

    public var detail: String {
        switch self {
        case .captureBound:
            "Host capture cadence is already below target."
        case .encodeBound:
            "Capture is healthy, but host encode throughput is behind target."
        case .hostCadenceLimited:
            "The host capture or encode pipeline is below the requested frame rate while transport pressure is clean."
        case .networkBound:
            "Transport pressure is dropping cadence before frames reach the client."
        case .decodeBound:
            "Frames reach the client faster than the decoder can sustain."
        case .presentationBound:
            "Decode keeps up, but the client render path is not enqueueing newest frames at target cadence."
        case .mixed:
            "More than one stage is limiting the stream at once."
        case .unknown:
            "No single limiting stage is clear from the current telemetry."
        }
    }

    public static func classify(snapshot: MirageClientMetricsSnapshot?) -> MirageStreamBottleneckKind {
        guard let snapshot, snapshot.hasHostMetrics else {
            return .unknown
        }

        let targetFPS = Double(max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60))
        let hostEncodedFPS = max(0, snapshot.hostEncodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let decodedFPS = max(0, snapshot.decodedFPS)
        let rendererEnqueueFPS = max(0, snapshot.clientRendererEnqueueFPS)
        let uniqueRendererEnqueueFPS = max(0, snapshot.clientUniqueRendererEnqueueFPS)
        let deliveredSourceFrameFPS = max(0, snapshot.clientUniqueDeliveredSourceFrameFPS)
        let hasDeliveredSourceFrameCadence = snapshot.clientDeliveredSourceFrameCadenceKnown
        let presentationFPS = hasDeliveredSourceFrameCadence ? deliveredSourceFrameFPS : 0
        let captureIngressFPS = max(0, snapshot.hostCaptureIngressFPS ?? 0)
        let captureFPS = max(0, snapshot.hostCaptureFPS ?? 0)
        let encodeAttemptFPS = max(0, snapshot.hostEncodeAttemptFPS ?? 0)
        let frameBudgetMs = max(0, snapshot.hostFrameBudgetMs ?? 0)
        let averageEncodeMs = max(0, snapshot.hostAverageEncodeMs ?? 0)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = snapshot.hostStalePacketDrops ?? 0
        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: queueBytes,
                queueStressBytes: 800_000,
                queueSevereBytes: 2_000_000,
                packetPacerAverageSleepMs: packetPacerAverageSleepMs,
                packetPacerStressThresholdMs: 0.75,
                packetPacerSevereThresholdMs: 2.0,
                sendStartDelayAverageMs: sendStartDelayAverageMs,
                sendStartDelayStressThresholdMs: 2.0,
                sendStartDelaySevereThresholdMs: 6.0,
                sendCompletionAverageMs: sendCompletionAverageMs,
                sendCompletionStressThresholdMs: 12.0,
                sendCompletionSevereThresholdMs: 28.0,
                transportDropCount: transportDropCount,
                transportDropSevereCount: 12,
                encodedFPS: hostEncodedFPS,
                deliveredFPS: receivedFPS,
                deliveryStressRatio: 0.92,
                deliverySevereRatio: 0.75
            )
        )
        let fpsGapGrace = max(4.0, targetFPS * 0.08)
        let decodeGapGrace = max(5.0, targetFPS * 0.10)
        let presentationGapGrace = max(4.0, targetFPS * 0.10)
        let presentationPendingAgeMsThreshold = max(20.0, (1_000.0 / targetFPS) * 1.5)
        let targetFrameIntervalMs = 1_000.0 / targetFPS
        let hostCaptureGapP99Ms = max(
            snapshot.hostCaptureDeliveredFrameGapP99Ms ?? 0,
            snapshot.hostCaptureWallClockGapP99Ms ?? 0,
            snapshot.hostCaptureDisplayTimeGapP99Ms ?? 0
        )
        let hostCaptureWorstGapMs = max(
            snapshot.hostCaptureDeliveredFrameGapWorstMs ?? 0,
            snapshot.hostCaptureWallClockGapWorstMs ?? 0,
            snapshot.hostCaptureDisplayTimeGapWorstMs ?? 0
        )
        let hostCaptureCadenceUneven =
            hostCaptureGapP99Ms >= max(35.0, targetFrameIntervalMs * 2.0) ||
            hostCaptureWorstGapMs >= max(60.0, targetFrameIntervalMs * 3.0) ||
            (snapshot.hostCaptureLongFrameGapCount ?? 0) > 0 ||
            snapshot.hostCaptureVirtualDisplayTimingSuspect == true
        let unevenPresentationCadence =
            max(snapshot.clientWorstPresentationGapMs, snapshot.clientVisibleWorstPresentationGapMs) >=
                max(80.0, targetFrameIntervalMs * 3.0) ||
            max(snapshot.clientFrameIntervalP99Ms, snapshot.clientVisibleFrameIntervalP99Ms) >=
                max(40.0, targetFrameIntervalMs * 2.0) ||
            snapshot.clientDisplayTickIntervalP99Ms >= max(40.0, targetFrameIntervalMs * 2.0) ||
            snapshot.clientMissedVSyncCount > 0 ||
            snapshot.clientVisiblePresentationStallCount > 0
        let unevenReceiveCadence =
            snapshot.clientReceivedWorstGapMs >= max(80.0, targetFrameIntervalMs * 4.0) ||
            snapshot.clientLoomStreamDeliveryGapMaxMs >= max(80.0, targetFrameIntervalMs * 4.0) ||
            snapshot.clientIncomingMediaBatchIntervalMaxMs >= max(80.0, targetFrameIntervalMs * 4.0)
        let severeUnevenPresentationCadence =
            max(snapshot.clientWorstPresentationGapMs, snapshot.clientVisibleWorstPresentationGapMs) >=
                max(180.0, targetFrameIntervalMs * 8.0) ||
            max(snapshot.clientFrameIntervalP99Ms, snapshot.clientVisibleFrameIntervalP99Ms) >=
                max(100.0, targetFrameIntervalMs * 6.0) ||
            snapshot.clientDisplayTickIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0)

        let decodeQueueBacklogPressure = snapshot.clientDecodeQueueBacklogFrames > max(
            1,
            snapshot.clientDecodeSubmissionLimit
        )
        let decodeSubmissionSaturated = snapshot.clientDecodeSubmissionLimit > 0 &&
            snapshot.clientDecodeSubmissionInFlightCount >= snapshot.clientDecodeSubmissionLimit
        let decodeHasClientPressure = !snapshot.decodeHealthy ||
            decodeQueueBacklogPressure ||
            decodeSubmissionSaturated
        let decodeRecoveryCollapse = decodeHasClientPressure &&
            hostEncodedFPS >= targetFPS * 0.75 &&
            decodedFPS < targetFPS * 0.50 &&
            rendererEnqueueFPS < targetFPS * 0.50 &&
            uniqueRendererEnqueueFPS < targetFPS * 0.50 &&
            (!hasDeliveredSourceFrameCadence || presentationFPS < targetFPS * 0.50)
        let decodeHealthCadenceDeficit = decodeHasClientPressure &&
            hostEncodedFPS >= targetFPS * 0.75 &&
            decodedFPS < targetFPS * 0.85 &&
            rendererEnqueueFPS < targetFPS * 0.90 &&
            uniqueRendererEnqueueFPS < targetFPS * 0.90 &&
            (!hasDeliveredSourceFrameCadence || presentationFPS < targetFPS * 0.90)
        let decodeBound = (
            receivedFPS > 0 &&
                decodedFPS + decodeGapGrace < receivedFPS &&
                (decodeHasClientPressure || receivedFPS >= targetFPS * 0.75)
        ) || decodeRecoveryCollapse ||
            decodeHealthCadenceDeficit

        let decodeKeepsUp = snapshot.decodeHealthy &&
            decodedFPS >= targetFPS * 0.75 &&
            (receivedFPS <= 0 || decodedFPS + decodeGapGrace >= receivedFPS)
        let deliveredFramesLaggingDecode = hasDeliveredSourceFrameCadence &&
            presentationFPS + presentationGapGrace < decodedFPS
        let rendererEnqueueLaggingDecode = rendererEnqueueFPS > 0 &&
            rendererEnqueueFPS + presentationGapGrace < decodedFPS
        let uniqueRendererEnqueueLaggingDecode = uniqueRendererEnqueueFPS > 0 &&
            uniqueRendererEnqueueFPS + presentationGapGrace < decodedFPS
        let presentationBackpressure = snapshot.clientOverwrittenPendingFrames > 0 ||
            snapshot.clientLateFrameDrops > 0 ||
            snapshot.clientDisplayLayerNotReadyCount > 0 ||
            snapshot.clientPendingFrameAgeMs >= presentationPendingAgeMsThreshold ||
            snapshot.clientRenderQueueBacklogFrames > max(1, snapshot.clientPlayoutDelayFrames + 1) ||
            snapshot.clientRepeatedDeliveredSourceFrameCount > 0
        let clientRenderPressure = presentationBackpressure ||
            deliveredFramesLaggingDecode ||
            rendererEnqueueLaggingDecode ||
            uniqueRendererEnqueueLaggingDecode ||
            unevenPresentationCadence ||
            severeUnevenPresentationCadence
        let networkBound = transportAssessment.isStress && !transportAssessment.isPacerOnlyStress ||
            !decodeHasClientPressure &&
            unevenReceiveCadence &&
                hostEncodedFPS >= targetFPS * 0.75 &&
                !decodeBound &&
                !clientRenderPressure
        let presentationBound = decodeKeepsUp && (
            deliveredFramesLaggingDecode && (presentationBackpressure || unevenPresentationCadence) ||
                hasDeliveredSourceFrameCadence &&
                    unevenPresentationCadence &&
                    presentationFPS < targetFPS * 0.97 ||
                hasDeliveredSourceFrameCadence &&
                    severeUnevenPresentationCadence &&
                    presentationFPS >= targetFPS * 0.90 ||
                !hasDeliveredSourceFrameCadence &&
                    (rendererEnqueueLaggingDecode || uniqueRendererEnqueueLaggingDecode) &&
                    presentationBackpressure
        ) || rendererEnqueueFPS >= targetFPS * 0.75 &&
            hasDeliveredSourceFrameCadence &&
            presentationFPS < targetFPS * 0.50 &&
            clientRenderPressure

        let hostCadenceLimited = !networkBound && (
                (captureIngressFPS > 0 && captureIngressFPS < targetFPS * 0.90) ||
                (captureFPS > 0 && captureFPS < targetFPS * 0.90) ||
                (encodeAttemptFPS > 0 && encodeAttemptFPS < targetFPS * 0.90) ||
                hostCaptureCadenceUneven
        )

        let captureBound = !hostCadenceLimited && (
            (captureIngressFPS > 0 && captureIngressFPS < targetFPS * 0.90) ||
            (captureFPS > 0 && captureFPS < targetFPS * 0.90 && encodeAttemptFPS <= captureFPS + 3.0)
        )

        let encodeHasWork = (encodeAttemptFPS > 0 && encodeAttemptFPS >= targetFPS * 0.90) ||
            (captureFPS > 0 && captureFPS >= targetFPS * 0.90)
        let encodeThroughputBelowSource = encodeAttemptFPS > 0 &&
            hostEncodedFPS < targetFPS * 0.90 &&
            hostEncodedFPS + fpsGapGrace < encodeAttemptFPS
        let encodeCostOverBudget = encodeHasWork &&
            hostEncodedFPS < targetFPS * 0.95 &&
            frameBudgetMs > 0 &&
            averageEncodeMs > frameBudgetMs * 1.05
        let encodeBound = encodeThroughputBelowSource || encodeCostOverBudget

        let activeKinds = [
            captureBound ? MirageStreamBottleneckKind.captureBound : nil,
            encodeBound ? .encodeBound : nil,
            hostCadenceLimited ? .hostCadenceLimited : nil,
            networkBound ? .networkBound : nil,
            decodeBound ? .decodeBound : nil,
            presentationBound ? .presentationBound : nil,
        ]
        .compactMap { $0 }

        if activeKinds.count > 1 {
            return .mixed
        }
        return activeKinds.first ?? .unknown
    }
}

public extension MirageClientMetricsSnapshot {
    var bottleneckKind: MirageStreamBottleneckKind {
        MirageStreamBottleneckKind.classify(snapshot: self)
    }
}
