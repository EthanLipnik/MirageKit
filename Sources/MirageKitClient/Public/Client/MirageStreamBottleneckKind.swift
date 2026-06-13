//
//  MirageStreamBottleneckKind.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

/// Dominant stage currently limiting stream cadence or quality.
public enum MirageStreamBottleneckKind: String, Sendable, Equatable {
    /// Host capture cadence is the limiting stage.
    case captureBound
    /// Host encoder throughput is the limiting stage.
    case encodeBound
    /// Host capture or encode cadence is below target while transport pressure is clean.
    case hostCadenceLimited
    /// Transport pressure is the limiting stage.
    case networkBound
    /// Client decoder throughput is the limiting stage.
    case decodeBound
    /// Client presentation/render cadence is the limiting stage.
    case presentationBound
    /// Multiple stages are limiting the stream.
    case mixed
    /// No clear limiting stage is visible in current telemetry.
    case unknown

    /// Short user-facing label.
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

    /// Longer explanation suitable for diagnostics UI.
    public var detail: String {
        switch self {
        case .captureBound:
            "Host capture cadence is already below target."
        case .encodeBound:
            "Capture is healthy, but host encode throughput is behind target."
        case .hostCadenceLimited:
            "The host is capturing or encoding below the requested frame rate while transport pressure is not the primary limiter."
        case .networkBound:
            "Transport pressure is dropping cadence before frames reach the client."
        case .decodeBound:
            "Frames reach the client faster than the decoder can sustain."
        case .presentationBound:
            "Decode keeps up, but the client render path is not presenting the newest frames at target cadence."
        case .mixed:
            "More than one stage is limiting the stream at once."
        case .unknown:
            "No single limiting stage is clear from the current telemetry."
        }
    }

    /// Classifies the dominant bottleneck from client and host metrics.
    public static func classify(snapshot: MirageClientMetricsSnapshot?) -> MirageStreamBottleneckKind {
        guard let snapshot, snapshot.hasHostMetrics else {
            return .unknown
        }

        let targetFPS = Double(max(1, snapshot.hostTargetFrameRate > 0 ? snapshot.hostTargetFrameRate : 60))
        let hostEncodedFPS = max(0, snapshot.hostEncodedFPS)
        let receivedFPS = max(0, snapshot.receivedFPS)
        let decodedFPS = max(0, snapshot.decodedFPS)
        let submittedFPS = max(0, snapshot.submittedFPS)
        let uniqueSubmittedFPS = max(0, snapshot.uniqueSubmittedFPS)
        let captureIngressFPS = max(0, snapshot.hostCaptureIngressFPS ?? 0)
        let captureFPS = max(0, snapshot.hostCaptureFPS ?? 0)
        let encodeAttemptFPS = max(0, snapshot.hostEncodeAttemptFPS ?? 0)
        let frameBudgetMs = max(0, snapshot.hostFrameBudgetMs ?? 0)
        let averageEncodeMs = max(0, snapshot.hostAverageEncodeMs ?? 0)
        let queueBytes = max(0, snapshot.hostSendQueueBytes ?? 0)
        let sendStartDelayAverageMs = max(0, snapshot.hostSendStartDelayAverageMs ?? 0)
        let sendCompletionAverageMs = max(0, snapshot.hostSendCompletionAverageMs ?? 0)
        let packetPacerAverageSleepMs = max(0, snapshot.hostPacketPacerAverageSleepMs ?? 0)
        let transportDropCount = snapshot.hostTransportPressureDropCount
        let transportAdmissionSkips = snapshot.hostTransportAdmissionSkips ?? 0
        let transportAdmissionActive = transportAdmissionSkips > 0 ||
            (snapshot.hostTransportAdmissionActiveHoldMs ?? 0) > 0
        let transportAssessment = MirageTransportPressure.assess(
            sample: MirageTransportPressureSample(
                queueBytes: queueBytes,
                queueStressBytes: 800_000,
                packetPacerAverageSleepMs: packetPacerAverageSleepMs,
                packetPacerStressThresholdMs: 0.75,
                sendStartDelayAverageMs: sendStartDelayAverageMs,
                sendStartDelayStressThresholdMs: 2.0,
                sendCompletionAverageMs: sendCompletionAverageMs,
                sendCompletionStressThresholdMs: 12.0,
                transportDropCount: transportDropCount
            )
        )
        let fpsGapGrace = max(4.0, targetFPS * 0.08)
        let decodeGapGrace = max(5.0, targetFPS * 0.10)
        let presentationGapGrace = max(4.0, targetFPS * 0.10)
        let presentationPendingAgeMsThreshold = max(20.0, (1000.0 / targetFPS) * 1.5)
        let targetFrameIntervalMs = 1000.0 / targetFPS
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
            snapshot.clientWorstPresentationGapMs >= max(80.0, targetFrameIntervalMs * 3.0) ||
            snapshot.clientFrameIntervalP99Ms >= max(40.0, targetFrameIntervalMs * 2.0) ||
            snapshot.clientDisplayTickIntervalP99Ms >= max(40.0, targetFrameIntervalMs * 2.0) ||
            snapshot.clientMissedVSyncCount > 0
        let severeUnevenPresentationCadence =
            snapshot.clientWorstPresentationGapMs >= max(180.0, targetFrameIntervalMs * 8.0) ||
            snapshot.clientFrameIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0) ||
            snapshot.clientDisplayTickIntervalP99Ms >= max(100.0, targetFrameIntervalMs * 6.0)
        let rendererLoopStalled =
            submittedFPS >= targetFPS * 0.75 &&
            uniqueSubmittedFPS + presentationGapGrace < submittedFPS &&
            snapshot.pendingFrameCount > 0

        let networkBound = transportAdmissionActive ||
            (transportAssessment.primaryStress && !transportAssessment.isPacerOnlyStress)
        let sourceOrRecoveryCadenceLimited =
            max(receivedFPS, decodedFPS) > 0 &&
            max(receivedFPS, decodedFPS) < targetFPS * 0.85 &&
            abs(receivedFPS - decodedFPS) <= decodeGapGrace

        let decodeBound = (!snapshot.decodeHealthy && receivedFPS > 0 && decodedFPS + decodeGapGrace < receivedFPS) ||
            (receivedFPS >= targetFPS * 0.75 && decodedFPS + decodeGapGrace < receivedFPS) ||
            (!snapshot.decodeHealthy &&
                !sourceOrRecoveryCadenceLimited &&
                !rendererLoopStalled &&
                !networkBound &&
                hostEncodedFPS >= targetFPS * 0.90 &&
                max(receivedFPS, decodedFPS) < targetFPS * 0.85)

        let decodeKeepsUp = snapshot.decodeHealthy &&
            decodedFPS >= targetFPS * 0.75 &&
            (receivedFPS <= 0 || decodedFPS + decodeGapGrace >= receivedFPS)
        let hostCadenceLimited = !networkBound && (
            (captureIngressFPS > 0 && captureIngressFPS < targetFPS * 0.90) ||
                (captureFPS > 0 && captureFPS < targetFPS * 0.90) ||
                (encodeAttemptFPS > 0 && encodeAttemptFPS < targetFPS * 0.90) ||
                hostCaptureCadenceUneven
        )
        let presentationHealthyEnoughToAvoidBlame =
            decodedFPS >= targetFPS - 1.0 &&
            snapshot.clientDisplayTickFPS >= targetFPS - 1.0 &&
            snapshot.clientDisplayLayerNotReadyCount == 0
        let submissionLaggingDecode = (submittedFPS + presentationGapGrace < decodedFPS) ||
            (uniqueSubmittedFPS + presentationGapGrace < decodedFPS)
        let visibleFPS = max(0, snapshot.clientPresentedFPS)
        let visibleLaggingSubmission = visibleFPS > 0 &&
            visibleFPS + presentationGapGrace < max(uniqueSubmittedFPS, submittedFPS)
        let presentationBackpressure = snapshot.clientOverwrittenPendingFrames > 0 ||
            snapshot.clientLateFrameDrops > 0 ||
            snapshot.clientDisplayLayerNotReadyCount > 0 ||
            snapshot.clientPendingFrameAgeMs >= presentationPendingAgeMsThreshold
        let presentationBound = !hostCadenceLimited && !presentationHealthyEnoughToAvoidBlame && (
            rendererLoopStalled ||
                decodeKeepsUp && (
                submissionLaggingDecode && (presentationBackpressure || unevenPresentationCadence) ||
                    visibleLaggingSubmission && (unevenPresentationCadence || snapshot.clientRepeatedFrameCount > 0) ||
                    unevenPresentationCadence && submittedFPS < targetFPS * 0.97 ||
                    severeUnevenPresentationCadence && submittedFPS >= targetFPS * 0.90
            )
            )

        let captureBound = !hostCadenceLimited && (
            (captureIngressFPS > 0 && captureIngressFPS < targetFPS * 0.90) ||
                (captureFPS > 0 && captureFPS < targetFPS * 0.90 && encodeAttemptFPS <= captureFPS + 3.0)
        )

        let encodeHasWork = (encodeAttemptFPS > 0 && encodeAttemptFPS >= targetFPS * 0.90) ||
            (captureFPS > 0 && captureFPS >= targetFPS * 0.90)
        let encodeThroughputFloor = min(encodeAttemptFPS, targetFPS)
        let encodeBound = (encodeAttemptFPS > 0 && hostEncodedFPS + fpsGapGrace < encodeThroughputFloor) ||
            (encodeHasWork && frameBudgetMs > 0 && averageEncodeMs > frameBudgetMs * 1.05)

        let activeKinds = [
            captureBound ? MirageStreamBottleneckKind.captureBound : nil,
            encodeBound ? .encodeBound : nil,
            hostCadenceLimited ? .hostCadenceLimited : nil,
            networkBound ? .networkBound : nil,
            decodeBound ? .decodeBound : nil,
            presentationBound ? .presentationBound : nil,
        ]
            .compactMap(\.self)

        if activeKinds.count > 1 {
            return .mixed
        }
        return activeKinds.first ?? .unknown
    }
}

public extension MirageClientMetricsSnapshot {
    /// Dominant stream bottleneck inferred from this metrics snapshot.
    var bottleneckKind: MirageStreamBottleneckKind {
        MirageStreamBottleneckKind.classify(snapshot: self)
    }
}
