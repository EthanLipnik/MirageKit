import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageDiagnostics.MirageClientMetricsSnapshot.swift
//  MirageKitClient
//
//  Created by Ethan Lipnik on 6/5/26.
//



extension MirageDiagnostics.MirageClientMetricsSnapshot {
    /// Applies host capture cadence telemetry while preserving existing client and encoder metrics.
    mutating func applyHostCaptureCadence(_ cadence: MirageWire.StreamCaptureCadenceMetrics?) {
        hostCaptureWallClockGapWorstMs = cadence?.wallClockGapWorstMs
        hostCaptureWallClockGapP95Ms = cadence?.wallClockGapP95Ms
        hostCaptureWallClockGapP99Ms = cadence?.wallClockGapP99Ms
        hostCaptureDisplayTimeGapWorstMs = cadence?.displayTimeGapWorstMs
        hostCaptureDisplayTimeGapP95Ms = cadence?.displayTimeGapP95Ms
        hostCaptureDisplayTimeGapP99Ms = cadence?.displayTimeGapP99Ms
        hostCaptureDeliveredFrameGapWorstMs = cadence?.deliveredFrameGapWorstMs
        hostCaptureDeliveredFrameGapP95Ms = cadence?.deliveredFrameGapP95Ms
        hostCaptureDeliveredFrameGapP99Ms = cadence?.deliveredFrameGapP99Ms
        hostCaptureCallbackP95Ms = cadence?.callbackDurationP95Ms
        hostCaptureCallbackP99Ms = cadence?.callbackDurationP99Ms
        hostCaptureLongFrameGapCount = cadence?.longFrameGapCount
        hostCaptureDisplayTimeDriftCount = cadence?.displayTimeDriftCount
        hostCaptureVirtualDisplayTimingSuspect = cadence?.virtualDisplayTimingSuspect
        hostSCKSampleDurationSeconds = cadence?.sampleDurationSeconds
        hostRawScreenCallbackFPS = cadence?.rawScreenCallbackFPS
        hostCompleteFrameFPS = cadence?.completeFrameFPS
        hostRenderableFrameFPS = cadence?.renderableFrameFPS
        hostCadenceAdmittedFrameFPS = cadence?.cadenceAdmittedFrameFPS
        hostObservedSCKFPS = cadence?.observedSCKFPS
        hostRawScreenCallbackCount = cadence?.rawScreenCallbackCount
        hostCompleteFrameCount = cadence?.completeFrameCount
        hostRenderableFrameCount = cadence?.renderableFrameCount
        hostIdleFrameCount = cadence?.idleFrameCount
        hostCadenceAdmittedFrameCount = cadence?.cadenceAdmittedFrameCount
        hostCaptureUsesDisplayRefreshCadence = cadence?.usesDisplayRefreshCadence
        hostCaptureUsesNativeRefreshMinimumFrameInterval = cadence?.usesNativeRefreshMinimumFrameInterval
        hostCaptureMinimumFrameIntervalRate = cadence?.minimumFrameIntervalRate
        hostCaptureDisplayRefreshRate = cadence?.displayRefreshRate
        hostVirtualDisplayID = cadence?.virtualDisplayID
        hostVirtualDisplayRefreshRate = cadence?.virtualDisplayRefreshRate
        hostVirtualDisplayScaleFactor = cadence?.virtualDisplayScaleFactor
    }
}

public extension MirageDiagnostics.MirageClientMetricsSnapshot {
    /// True only when the host is actually producing frames at roughly target
    /// cadence. ScreenCaptureKit is dynamic-fps: when the host produces few
    /// frames (static content or a capture-cadence deficit) the resulting
    /// inter-arrival gaps and low decode FPS are expected, not network
    /// congestion, and must not suppress bitrate probing. Mirrors the
    /// receiver-health delivery-cadence gate.
    var hostIsProducingAtCadence: Bool {
        let targetFPS = Double(max(1, hostTargetFrameRate))
        let hostEncodedFPS = max(0, hostEncodedFPS)
        return hostEncodedFPS >= targetFPS * MirageReceiverHealthController.hostDeliveryCadenceHealthyRatio
    }

    var hostOwnsRealtimeAdaptation: Bool {
        (hostAdaptiveGovernorRevision ?? 0) >= MirageAdaptiveGovernorProtocol.revision ||
            (hostRealtimeControlRevision ?? 0) >= 1
    }
}
