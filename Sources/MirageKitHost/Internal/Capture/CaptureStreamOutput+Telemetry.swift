//
//  CaptureStreamOutput+Telemetry.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//
//  Startup readiness and telemetry accounting for capture stream output.
//

import CoreMedia
import Foundation
import MirageKit

#if os(macOS)
import ScreenCaptureKit

extension CaptureStreamOutput {
    /// Lifetime telemetry counters for capture diagnostics.
    var telemetrySnapshot: TelemetrySnapshot {
        poolLogLock.withLock {
            let duration = max(0, CFAbsoluteTimeGetCurrent() - telemetryLifetimeStartTime)
            return TelemetrySnapshot(
                sampleDurationSeconds: duration,
                rawScreenCallbackCount: rawScreenCallbackCountCumulative,
                validScreenSampleCount: validScreenSampleCountCumulative,
                renderableScreenSampleCount: renderableScreenSampleCountCumulative,
                completeFrameCount: completeFrameCountCumulative,
                idleFrameCount: idleFrameCountCumulative,
                blankFrameCount: blankFrameCountCumulative,
                suspendedFrameCount: suspendedFrameCountCumulative,
                startedFrameCount: startedFrameCountCumulative,
                stoppedFrameCount: stoppedFrameCountCumulative,
                cadenceAdmittedFrameCount: cadenceAdmittedFrameCountCumulative,
                deliveredFrameCount: deliveredFrameCountCumulative,
                callbackDurationTotalMs: callbackDurationTotalCumulativeMs,
                callbackDurationMaxMs: callbackDurationMaxCumulativeMs,
                callbackSampleCount: callbackSampleCountCumulative,
                cadenceDropCount: cadenceDropTotalCount,
                admissionDropCount: admissionDropTotalCount,
                cadenceMetrics: cadenceMetrics.snapshot
            )
        }
    }

    /// Returns and clears the current diagnostics-window telemetry counters.
    func consumeTelemetrySnapshot() -> TelemetrySnapshot {
        poolLogLock.withLock {
            let now = CFAbsoluteTimeGetCurrent()
            let duration = max(0, now - telemetryWindowStartTime)
            let cadenceSnapshot = cadenceMetrics.consumeSnapshot()
            let snapshot = TelemetrySnapshot(
                sampleDurationSeconds: duration,
                rawScreenCallbackCount: rawScreenCallbackCountWindow,
                validScreenSampleCount: validScreenSampleCountWindow,
                renderableScreenSampleCount: renderableScreenSampleCountWindow,
                completeFrameCount: completeFrameCountWindow,
                idleFrameCount: idleFrameCountWindow,
                blankFrameCount: blankFrameCountWindow,
                suspendedFrameCount: suspendedFrameCountWindow,
                startedFrameCount: startedFrameCountWindow,
                stoppedFrameCount: stoppedFrameCountWindow,
                cadenceAdmittedFrameCount: cadenceAdmittedFrameCountWindow,
                deliveredFrameCount: deliveredFrameCountWindow,
                callbackDurationTotalMs: callbackDurationTotalMs,
                callbackDurationMaxMs: callbackDurationMaxMs,
                callbackSampleCount: callbackSampleCount,
                cadenceDropCount: cadenceDropCount,
                admissionDropCount: admissionDropCount,
                cadenceMetrics: cadenceSnapshot
            )
            callbackDurationTotalMs = 0
            callbackDurationMaxMs = 0
            callbackSampleCount = 0
            cadenceDropCount = 0
            admissionDropCount = 0
            rawScreenCallbackCountWindow = 0
            validScreenSampleCountWindow = 0
            renderableScreenSampleCountWindow = 0
            completeFrameCountWindow = 0
            idleFrameCountWindow = 0
            blankFrameCountWindow = 0
            suspendedFrameCountWindow = 0
            startedFrameCountWindow = 0
            stoppedFrameCountWindow = 0
            cadenceAdmittedFrameCountWindow = 0
            deliveredFrameCountWindow = 0
            telemetryWindowStartTime = now
            return snapshot
        }
    }

    func noteCaptureStartupSample(status: SCFrameStatus) {
        var blankOrSuspendedStatusName: String?
        var lifecycleStatusName: String?
        startupReadinessLock.withLock {
            startupReadinessState.hasObservedSample = true
            switch status {
            case .complete:
                startupReadinessState.hasUsableFrame = true
            case .idle:
                startupReadinessState.hasIdleFrame = true
            case .blank:
                startupReadinessState.blankOrSuspendedCount &+= 1
                if windowID == 0, !startupReadinessState.hasLoggedBlankOrSuspended {
                    startupReadinessState.hasLoggedBlankOrSuspended = true
                    blankOrSuspendedStatusName = "blank"
                }
            case .suspended:
                startupReadinessState.blankOrSuspendedCount &+= 1
                if windowID == 0, !startupReadinessState.hasLoggedBlankOrSuspended {
                    startupReadinessState.hasLoggedBlankOrSuspended = true
                    blankOrSuspendedStatusName = "suspended"
                }
            case .started:
                if windowID == 0, !startupReadinessState.hasLoggedLifecycleSample {
                    startupReadinessState.hasLoggedLifecycleSample = true
                    lifecycleStatusName = "started"
                }
            case .stopped:
                if windowID == 0, !startupReadinessState.hasLoggedLifecycleSample {
                    startupReadinessState.hasLoggedLifecycleSample = true
                    lifecycleStatusName = "stopped"
                }
            default:
                break
            }
        }

        if let blankOrSuspendedStatusName {
            MirageLogger.capture(
                "Display startup sample status=\(blankOrSuspendedStatusName) while waiting for first usable frame"
            )
        }
        if let lifecycleStatusName {
            MirageLogger.capture(
                "Display startup lifecycle status=\(lifecycleStatusName) before first renderable frame"
            )
        }
    }

    func resolvedFrameStatus(
        from attachments: [SCStreamFrameInfo: Any]?
    ) -> SCFrameStatus? {
        guard let attachments,
              let statusRawValue = attachments[.status] as? Int else {
            return nil
        }
        return SCFrameStatus(rawValue: statusRawValue)
    }

    func recordCallbackDuration(_ durationMs: Double) {
        poolLogLock.withLock {
            callbackDurationTotalMs += durationMs
            callbackDurationMaxMs = max(callbackDurationMaxMs, durationMs)
            callbackSampleCount += 1
            callbackDurationTotalCumulativeMs += durationMs
            callbackDurationMaxCumulativeMs = max(callbackDurationMaxCumulativeMs, durationMs)
            callbackSampleCountCumulative &+= 1
            cadenceMetrics.recordCallbackDuration(durationMs)
        }
    }

    func recordRawScreenCallback(at captureTime: CFAbsoluteTime) {
        poolLogLock.withLock {
            rawScreenCallbackCountWindow &+= 1
            rawScreenCallbackCountCumulative &+= 1
            cadenceMetrics.recordScreenCallback(at: captureTime)
        }
    }

    func recordFrameTiming(displayTimeSeconds: Double?) {
        poolLogLock.withLock {
            cadenceMetrics.recordFrameTiming(displayTime: displayTimeSeconds)
        }
    }

    func recordValidScreenSample() {
        poolLogLock.withLock {
            validScreenSampleCountWindow &+= 1
            validScreenSampleCountCumulative &+= 1
        }
    }

    func recordFrameStatus(_ status: SCFrameStatus) {
        poolLogLock.withLock {
            switch status {
            case .complete:
                completeFrameCountWindow &+= 1
                completeFrameCountCumulative &+= 1
            case .idle:
                idleFrameCountWindow &+= 1
                idleFrameCountCumulative &+= 1
            case .blank:
                blankFrameCountWindow &+= 1
                blankFrameCountCumulative &+= 1
                cadenceMetrics.recordLimitedStatus(.blank)
            case .suspended:
                suspendedFrameCountWindow &+= 1
                suspendedFrameCountCumulative &+= 1
                cadenceMetrics.recordLimitedStatus(.suspended)
            case .started:
                startedFrameCountWindow &+= 1
                startedFrameCountCumulative &+= 1
            case .stopped:
                stoppedFrameCountWindow &+= 1
                stoppedFrameCountCumulative &+= 1
                cadenceMetrics.recordLimitedStatus(.stopped)
            @unknown default:
                break
            }
        }
    }

    func recordRenderableScreenSample() {
        poolLogLock.withLock {
            renderableScreenSampleCountWindow &+= 1
            renderableScreenSampleCountCumulative &+= 1
        }
    }

    func recordCadenceAdmittedFrame() {
        poolLogLock.withLock {
            cadenceAdmittedFrameCountWindow &+= 1
            cadenceAdmittedFrameCountCumulative &+= 1
        }
    }

    func recordDeliveredFrame(at captureTime: CFAbsoluteTime) {
        poolLogLock.withLock {
            deliveredFrameCountWindow &+= 1
            deliveredFrameCountCumulative &+= 1
            cadenceMetrics.recordDeliveredFrame(at: captureTime)
        }
    }
}
#endif
