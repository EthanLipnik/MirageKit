//
//  StreamContext+CaptureCadenceRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
extension StreamContext {
    func streamCaptureCadenceMetrics(
        telemetry: CaptureStreamOutput.TelemetrySnapshot?,
        policy: WindowCaptureEngine.CapturePolicySnapshot?
    ) -> MirageWire.StreamCaptureCadenceMetrics? {
        guard let telemetry else { return nil }
        let cadence = telemetry.cadenceMetrics
        let virtualDisplay = virtualDisplayContext
        let metrics = MirageWire.StreamCaptureCadenceMetrics(
            sampleDurationSeconds: telemetry.sampleDurationSeconds,
            rawScreenCallbackCount: telemetry.rawScreenCallbackCount,
            completeFrameCount: telemetry.completeFrameCount,
            renderableFrameCount: telemetry.renderableScreenSampleCount,
            idleFrameCount: telemetry.idleFrameCount,
            cadenceAdmittedFrameCount: telemetry.cadenceAdmittedFrameCount,
            rawScreenCallbackFPS: telemetry.rawScreenCallbackFPS,
            completeFrameFPS: telemetry.completeFrameFPS,
            renderableFrameFPS: telemetry.renderableFrameFPS,
            cadenceAdmittedFrameFPS: telemetry.cadenceAdmittedFrameFPS,
            observedSCKFPS: telemetry.observedSCKFPS,
            wallClockGapWorstMs: cadence.wallClockGapWorstMs,
            wallClockGapP95Ms: cadence.wallClockGapP95Ms,
            wallClockGapP99Ms: cadence.wallClockGapP99Ms,
            displayTimeGapWorstMs: cadence.displayTimeGapWorstMs,
            displayTimeGapP95Ms: cadence.displayTimeGapP95Ms,
            displayTimeGapP99Ms: cadence.displayTimeGapP99Ms,
            deliveredFrameGapWorstMs: cadence.deliveredFrameGapWorstMs,
            deliveredFrameGapP95Ms: cadence.deliveredFrameGapP95Ms,
            deliveredFrameGapP99Ms: cadence.deliveredFrameGapP99Ms,
            callbackDurationP95Ms: cadence.callbackDurationP95Ms,
            callbackDurationP99Ms: cadence.callbackDurationP99Ms,
            longFrameGapCount: cadence.longFrameGapCount,
            displayTimeDriftCount: cadence.displayTimeDriftCount,
            blankFrameStatusCount: cadence.blankFrameStatusCount,
            suspendedFrameStatusCount: cadence.suspendedFrameStatusCount,
            stoppedFrameStatusCount: cadence.stoppedFrameStatusCount,
            cadenceDropCount: cadence.cadenceDropCount,
            usesDisplayRefreshCadence: policy?.usesDisplayRefreshCadence,
            usesNativeRefreshMinimumFrameInterval: policy?.usesNativeRefreshMinimumFrameInterval,
            minimumFrameIntervalRate: policy?.minimumFrameIntervalRate,
            displayRefreshRate: policy?.displayRefreshRate,
            virtualDisplayID: virtualDisplay.map { UInt32($0.displayID) },
            virtualDisplayRefreshRate: virtualDisplay?.refreshRate,
            virtualDisplayScaleFactor: virtualDisplay.map { Double($0.scaleFactor) },
            virtualDisplayTimingSuspect: cadence.virtualDisplayTimingSuspect
        )
        lastCaptureCadenceMetrics = metrics
        return metrics
    }
}
#endif
