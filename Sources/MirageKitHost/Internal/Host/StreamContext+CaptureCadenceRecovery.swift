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
            receiverHasPresentedFrame: receiverHasPresentedFrame,
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
        guard action != .none else {
            logSuppressedCaptureCadenceRecoveryIfNeeded()
            return
        }
        await performCaptureCadenceRecovery(action, captureCadence: captureCadence)
    }

    private func logSuppressedCaptureCadenceRecoveryIfNeeded() {
        guard captureCadenceRecoveryPolicy.lastSuppressionReason == .receiverAlreadyPresented,
              let action = captureCadenceRecoveryPolicy.lastSuppressedAction else {
            return
        }
        MirageLogger.capture(
            "event=capture_cadence_recovery action=\(action.logName) result=skipped_receiver_presented stream=\(streamID)"
        )
    }

    func performCaptureCadenceRecovery(
        _ action: HostCaptureCadenceRecoveryPolicy.Action,
        captureCadence: StreamCaptureCadenceMetrics?
    ) async {
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
        func fpsText(_ value: Double?) -> String {
            value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--"
        }
        func intText(_ value: Int?) -> String {
            value.map(String.init) ?? "--"
        }
        let virtualRefreshText = if let captureCadence,
                                    let virtualDisplayRefreshRate = captureCadence.virtualDisplayRefreshRate {
            virtualDisplayRefreshRate.formatted(.number.precision(.fractionLength(1)))
        } else {
            "--"
        }
        let nativeRefreshText = if let captureCadence,
                                   let usesNativeRefresh = captureCadence.usesNativeRefreshMinimumFrameInterval {
            usesNativeRefresh ? "true" : "false"
        } else {
            "--"
        }
        let cadenceText = "target=\(currentFrameRate)fps " +
            "capture=\(fpsText(lastCaptureFPS))fps " +
            "ingress=\(fpsText(lastCaptureIngressFPS))fps " +
            "encodeAttempt=\(fpsText(lastEncodeAttemptFPS))fps " +
            "policyRate=\(intText(captureCadence?.minimumFrameIntervalRate))fps " +
            "displayRate=\(intText(captureCadence?.displayRefreshRate))Hz " +
            "virtualRate=\(virtualRefreshText)Hz " +
            "nativeInterval=\(nativeRefreshText)"

        switch action {
        case .none:
            return
        case .restartVirtualDisplayCadenceDriver:
            MirageLogger.capture(
                "event=capture_cadence_recovery action=restart_virtual_display_cadence_driver stream=\(streamID) p99Ms=\(p99Text) worstMs=\(worstText) \(cadenceText)"
            )
            if let snapshot = await SharedVirtualDisplayManager.shared.restartCadenceDriver(for: .desktopStream) {
                virtualDisplayContext = snapshot
                updateWindowCaptureVirtualDisplayState(snapshot)
            } else if let snapshot = virtualDisplayContext {
                await MainActor.run {
                    VirtualDisplayKeepaliveController.shared.restart(
                        displayID: snapshot.displayID,
                        spaceID: snapshot.spaceID,
                        refreshRate: snapshot.refreshRate
                    )
                }
            } else {
                MirageLogger.capture(
                    "event=capture_cadence_recovery action=restart_virtual_display_cadence_driver result=skipped_no_display"
                )
            }
        case .restartCapture:
            MirageLogger.capture(
                "event=capture_cadence_recovery action=restart_capture stream=\(streamID) p99Ms=\(p99Text) worstMs=\(worstText) \(cadenceText)"
            )
            await restartDisplayCaptureForCadenceRecovery(reason: "capture cadence recovery")
        case .reassertVirtualDisplayMode:
            MirageLogger.capture(
                "event=capture_cadence_recovery action=reassert_virtual_display stream=\(streamID) p99Ms=\(p99Text) worstMs=\(worstText) \(cadenceText)"
            )
            if let snapshot = await SharedVirtualDisplayManager.shared.reassertDisplayMode(for: .desktopStream) {
                virtualDisplayContext = snapshot
                updateWindowCaptureVirtualDisplayState(snapshot)
            } else {
                MirageLogger.capture("event=capture_cadence_recovery action=reassert_virtual_display result=failed")
            }
            await restartDisplayCaptureForCadenceRecovery(reason: "capture cadence virtual-display reassert")
        case .recreateVirtualDisplay:
            MirageLogger.capture(
                "event=capture_cadence_recovery action=recreate_virtual_display stream=\(streamID) p99Ms=\(p99Text) worstMs=\(worstText) \(cadenceText)"
            )
            do {
                _ = try await SharedVirtualDisplayManager.shared.recreateDisplayForCadenceRecovery(for: .desktopStream)
            } catch {
                MirageLogger.error(.capture, error: error, message: "Capture cadence virtual-display recreate failed: ")
                await restartDisplayCaptureForCadenceRecovery(reason: "capture cadence recreate fallback")
            }
        }
    }

}

private extension HostCaptureCadenceRecoveryPolicy.Action {
    var logName: String {
        switch self {
        case .none:
            "none"
        case .restartVirtualDisplayCadenceDriver:
            "restart_virtual_display_cadence_driver"
        case .restartCapture:
            "restart_capture"
        case .reassertVirtualDisplayMode:
            "reassert_virtual_display"
        case .recreateVirtualDisplay:
            "recreate_virtual_display"
        }
    }
}
#endif
