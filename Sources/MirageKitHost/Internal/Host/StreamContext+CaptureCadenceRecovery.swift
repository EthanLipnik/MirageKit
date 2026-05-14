//
//  StreamContext+CaptureCadenceRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension StreamContext {
    func streamCaptureCadenceMetrics(
        telemetry: CaptureStreamOutput.TelemetrySnapshot?,
        policy: WindowCaptureEngine.CapturePolicySnapshot?
    ) -> StreamCaptureCadenceMetrics? {
        guard let telemetry else { return nil }
        let cadence = telemetry.cadenceMetrics
        let virtualDisplay = virtualDisplayContext
        let metrics = StreamCaptureCadenceMetrics(
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

    func applyCaptureCadenceRecoveryIfNeeded(
        captureCadence: StreamCaptureCadenceMetrics?,
        packetTelemetry: StreamPacketSender.TelemetrySnapshot?,
        averageEncodeMs: Double?,
        frameBudgetMs: Double,
        now: CFAbsoluteTime
    ) async {
        let sample = HostCaptureCadenceRecoveryPolicy.Sample(
            now: now,
            isDesktopDisplayStream: captureMode == .display && !isAppStream && virtualDisplayContext != nil,
            startupSettled: startupBaseTime == 0 || (startupRegistrationLogged && now - startupBaseTime >= 5.0),
            receiverHasPresentedFrame: false,
            isResizing: isResizing,
            isEncodingSuspendedForResize: encodingSuspendedForResize,
            targetFrameRate: currentFrameRate,
            captureFPS: lastCaptureFPS,
            captureIngressFPS: lastCaptureIngressFPS,
            encodeAttemptFPS: lastEncodeAttemptFPS,
            averageEncodeMs: averageEncodeMs,
            frameBudgetMs: frameBudgetMs,
            sendQueueBytes: packetTelemetry?.queuedBytes,
            queuePressureBytes: queuePressureBytes,
            sendStartDelayMaxMs: packetTelemetry?.sendStartDelayMaxMs,
            sendCompletionMaxMs: packetTelemetry?.sendCompletionMaxMs,
            packetPacerFrameMaxSleepMs: packetTelemetry?.packetPacerFrameMaxSleepMs,
            captureCadence: captureCadence
        )
        let action = captureCadenceRecoveryPolicy.evaluate(sample)
        guard action != .none else { return }
        logSuppressedCaptureCadenceRecovery(action, captureCadence: captureCadence)
    }

    func logSuppressedCaptureCadenceRecovery(
        _ action: HostCaptureCadenceRecoveryPolicy.Action,
        captureCadence: StreamCaptureCadenceMetrics?
    ) {
        let p99Text = if let captureCadence {
            captureCadence.deliveredFrameGapP99Ms.formatted(.number.precision(.fractionLength(1)))
        } else {
            "--"
        }
        let worstText = if let captureCadence {
            captureCadence.deliveredFrameGapWorstMs.formatted(.number.precision(.fractionLength(1)))
        } else {
            "--"
        }
        MirageLogger.capture(
            "event=capture_cadence_recovery action=\(String(describing: action)) " +
                "result=suppressed_no_capture_or_display_mutation stream=\(streamID) " +
                "p99Ms=\(p99Text) worstMs=\(worstText)"
        )
    }

}
#endif
