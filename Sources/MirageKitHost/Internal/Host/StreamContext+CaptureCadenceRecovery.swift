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

    func applyHighRefreshCaptureCadenceRecoveryIfNeeded(
        metrics: StreamCaptureCadenceMetrics?,
        policy: WindowCaptureEngine.CapturePolicySnapshot?,
        now: CFAbsoluteTime
    ) async {
        guard currentFrameRate >= HostHighRefreshCaptureCadenceRecoveryState.minimumHighRefreshTargetFPS,
              captureMode == .display,
              !mediaPathProfile.usesAwdlRadioPolicy,
              let metrics,
              let sampleDurationSeconds = metrics.sampleDurationSeconds,
              sampleDurationSeconds >= 0.75,
              let captureEngine,
              await captureEngine.isCapturing else {
            highRefreshCaptureCadenceRecoveryState.reset()
            return
        }

        let targetFPS = Double(max(1, currentFrameRate))
        let rawFPS = metrics.rawScreenCallbackFPS ?? metrics.completeFrameFPS ?? metrics.observedSCKFPS
        let observedFPS = metrics.observedSCKFPS ?? metrics.renderableFrameFPS ?? metrics.completeFrameFPS
        guard let effectiveFPS = effectiveHighRefreshSourceFPS(rawFPS: rawFPS, observedFPS: observedFPS) else {
            highRefreshCaptureCadenceRecoveryState.reset()
            return
        }

        let deficitThreshold = max(70.0, targetFPS * 0.70)
        let recoveryThreshold = max(80.0, targetFPS * 0.82)
        if effectiveFPS >= recoveryThreshold {
            highRefreshCaptureCadenceRecoveryState.noteHealthy(now: now)
            return
        }

        guard effectiveFPS < deficitThreshold,
              highRefreshCaptureCadenceRecoveryState.noteDeficit(now: now),
              highRefreshCaptureCadenceRecoveryState.canAct(now: now) else {
            return
        }

        let policyText = policy?.minimumFrameIntervalPolicy.rawValue ?? "unknown"
        let rawText = formattedOptionalFPS(rawFPS)
        let observedText = formattedOptionalFPS(observedFPS)
        let reason = "target=\(Int(targetFPS))fps raw=\(rawText) observed=\(observedText) policy=\(policyText)"

        switch highRefreshCaptureCadenceRecoveryState.stage {
        case .observing:
            await retuneHighRefreshCaptureCadence(
                to: .nativeRefresh,
                nextStage: .nativeRefreshRetuned,
                reason: reason,
                now: now
            )
        case .nativeRefreshRetuned:
            await retuneHighRefreshCaptureCadence(
                to: .explicitTarget,
                nextStage: .explicitTargetRetuned,
                reason: reason,
                now: now
            )
        case .explicitTargetRetuned:
            highRefreshCaptureCadenceRecoveryState.recordAction(.captureRestarted, now: now)
            MirageLogger.host(
                "High-refresh capture cadence recovery restarting capture for stream \(streamID): \(reason)"
            )
            await captureEngine.restartCapture(reason: "high_refresh_capture_cadence_deficit")
            await refreshCaptureCadence()
        case .captureRestarted:
            highRefreshCaptureCadenceRecoveryState.recordAction(.exhausted, now: now)
            MirageLogger.host(
                "High-refresh capture cadence recovery exhausted for stream \(streamID); " +
                    "leaving requested ProMotion cadence intact: \(reason)"
            )
        case .exhausted:
            break
        }
    }

    private func effectiveHighRefreshSourceFPS(rawFPS: Double?, observedFPS: Double?) -> Double? {
        switch (rawFPS, observedFPS) {
        case (.some(let raw), .some(let observed)):
            min(raw, observed)
        case (.some(let raw), .none):
            raw
        case (.none, .some(let observed)):
            observed
        case (.none, .none):
            nil
        }
    }

    private func retuneHighRefreshCaptureCadence(
        to policy: WindowCaptureEngine.MinimumFrameIntervalPolicy,
        nextStage: HostHighRefreshCaptureCadenceRecoveryState.Stage,
        reason: String,
        now: CFAbsoluteTime
    ) async {
        guard let captureEngine else { return }
        highRefreshCaptureCadenceRecoveryState.recordAction(nextStage, now: now)
        do {
            MirageLogger.host(
                "High-refresh capture cadence recovery retuning stream \(streamID) to \(policy.rawValue): \(reason)"
            )
            try await captureEngine.updateMinimumFrameIntervalPolicy(
                policy,
                reason: "high_refresh_capture_cadence_deficit"
            )
            await refreshCaptureCadence()
        } catch {
            MirageLogger.error(
                .host,
                error: error,
                message: "Failed to retune high-refresh capture cadence for stream \(streamID): "
            )
        }
    }

    private func formattedOptionalFPS(_ value: Double?) -> String {
        value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--"
    }
}
#endif
