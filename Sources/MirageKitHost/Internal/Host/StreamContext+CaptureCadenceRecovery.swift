//
//  StreamContext+CaptureCadenceRecovery.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit

#if os(macOS)
struct ScreenCaptureDeliveryRecovery: Sendable {
    enum Action: Sendable, Equatable {
        case none
        case retryNativeMinimumFrameInterval(reason: String)
        case restartStrengthenedKeepalive(reason: String)
        case downgradeFrameRate(fps: Int, reason: String)
    }

    struct Configuration: Sendable, Equatable {
        var validationWindowMinimumSeconds: CFAbsoluteTime = 0.75
        var healthyFPSRatio: Double = 0.90
        var actionCooldownSeconds: CFAbsoluteTime = 1.0
        var highRefreshMinimumTargetFPS: Int = 120
    }

    struct Sample: Sendable, Equatable {
        let now: CFAbsoluteTime
        let isDesktopDisplayStream: Bool
        let startupSettled: Bool
        let isResizing: Bool
        let isEncodingSuspendedForResize: Bool
        let targetFrameRate: Int
        let durationSeconds: Double
        let rawCallbackCount: UInt64
        let completeFrameCount: UInt64
        let renderableFrameCount: UInt64
        let idleFrameCount: UInt64
        let cadenceAdmittedFrameCount: UInt64
        let observedSCKFPS: Double?
        let renderableSCKFPS: Double?
        let cadenceAdmittedFPS: Double?
        let displayTimeGapP50Ms: Double
        let displayTimeGapP95Ms: Double
        let displayTimeGapP99Ms: Double
        let topologyLimitReason: String?
    }

    private enum Stage: Sendable, Equatable {
        case explicitTargetInterval
        case nativeIntervalRetried
        case strengthenedKeepaliveRetried
        case downgraded
    }

    var configuration = Configuration()
    private var stage: Stage = .explicitTargetInterval
    private var trackedTargetFrameRate: Int = 0
    private var lastActionTime: CFAbsoluteTime = 0

    mutating func reset() {
        stage = .explicitTargetInterval
        trackedTargetFrameRate = 0
        lastActionTime = 0
    }

    mutating func evaluate(_ sample: Sample) -> Action {
        let targetFrameRate = max(1, sample.targetFrameRate)
        if trackedTargetFrameRate != targetFrameRate {
            reset()
            trackedTargetFrameRate = targetFrameRate
        }

        guard sample.isDesktopDisplayStream,
              targetFrameRate >= configuration.highRefreshMinimumTargetFPS,
              sample.startupSettled,
              !sample.isResizing,
              !sample.isEncodingSuspendedForResize,
              sample.durationSeconds >= configuration.validationWindowMinimumSeconds else {
            return .none
        }

        let observedFPS = sample.observedSCKFPS ?? 0
        let healthyFloor = Double(targetFrameRate) * configuration.healthyFPSRatio
        guard observedFPS < healthyFloor else {
            return .none
        }

        if lastActionTime > 0, sample.now - lastActionTime < configuration.actionCooldownSeconds {
            return .none
        }

        let reason = sample.topologyLimitReason ?? "sck-delivery-below-target"
        lastActionTime = sample.now

        switch stage {
        case .explicitTargetInterval:
            stage = .nativeIntervalRetried
            return .retryNativeMinimumFrameInterval(reason: reason)
        case .nativeIntervalRetried:
            stage = .strengthenedKeepaliveRetried
            return .restartStrengthenedKeepalive(reason: reason)
        case .strengthenedKeepaliveRetried:
            stage = .downgraded
            return .downgradeFrameRate(
                fps: Self.stableDowngradeFrameRate(observedFPS: observedFPS, targetFrameRate: targetFrameRate),
                reason: reason
            )
        case .downgraded:
            return .none
        }
    }

    nonisolated static func stableDowngradeFrameRate(
        observedFPS: Double,
        targetFrameRate: Int
    ) -> Int {
        let targetFrameRate = max(1, targetFrameRate)
        let roundedObserved = max(1, Int(observedFPS.rounded()))
        let commonRates = [120, 100, 96, 90, 80, 72, 60, 50, 48, 40, 30, 24]
        for rate in commonRates where rate < targetFrameRate && Double(rate) <= observedFPS + 2.0 {
            return rate
        }
        return max(1, min(targetFrameRate - 1, roundedObserved))
    }
}

extension StreamContext {
    func streamCaptureCadenceMetrics(
        telemetry: CaptureStreamOutput.TelemetrySnapshot?,
        policy: WindowCaptureEngine.CapturePolicySnapshot?
    ) -> StreamCaptureCadenceMetrics? {
        guard let telemetry else { return nil }
        let cadence = telemetry.cadenceMetrics
        let virtualDisplay = virtualDisplayContext
        let metrics = StreamCaptureCadenceMetrics(
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

    func applyCaptureCadenceRecoveryIfNeeded(
        captureTelemetry: CaptureStreamOutput.TelemetrySnapshot?,
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
        let deliveryAction = screenCaptureDeliveryRecovery.evaluate(
            screenCaptureDeliveryRecoverySample(
                telemetry: captureTelemetry,
                sample: sample
            )
        )
        if deliveryAction != .none {
            await performScreenCaptureDeliveryRecovery(deliveryAction, telemetry: captureTelemetry)
            return
        }

        let action = captureCadenceRecoveryPolicy.evaluate(sample)
        guard action != .none else {
            logSuppressedCaptureCadenceRecoveryIfNeeded()
            return
        }
        await performCaptureCadenceRecovery(action, captureCadence: captureCadence)
    }

    private func screenCaptureDeliveryRecoverySample(
        telemetry: CaptureStreamOutput.TelemetrySnapshot?,
        sample: HostCaptureCadenceRecoveryPolicy.Sample
    ) -> ScreenCaptureDeliveryRecovery.Sample {
        let diagnostics = VirtualDisplayTopologyDiagnostics.snapshot(
            targetFrameRate: currentFrameRate,
            virtualDisplayID: virtualDisplayContext?.displayID
        )
        let cadence = telemetry?.cadenceMetrics
        return ScreenCaptureDeliveryRecovery.Sample(
            now: sample.now,
            isDesktopDisplayStream: sample.isDesktopDisplayStream,
            startupSettled: sample.startupSettled,
            isResizing: sample.isResizing,
            isEncodingSuspendedForResize: sample.isEncodingSuspendedForResize,
            targetFrameRate: sample.targetFrameRate,
            durationSeconds: telemetry?.sampleDurationSeconds ?? 0,
            rawCallbackCount: telemetry?.rawScreenCallbackCount ?? 0,
            completeFrameCount: telemetry?.completeFrameCount ?? 0,
            renderableFrameCount: telemetry?.renderableScreenSampleCount ?? 0,
            idleFrameCount: telemetry?.idleFrameCount ?? 0,
            cadenceAdmittedFrameCount: telemetry?.cadenceAdmittedFrameCount ?? 0,
            observedSCKFPS: telemetry?.observedSCKFPS,
            renderableSCKFPS: telemetry?.renderableFrameFPS,
            cadenceAdmittedFPS: telemetry?.cadenceAdmittedFrameFPS,
            displayTimeGapP50Ms: cadence?.displayTimeGapP50Ms ?? 0,
            displayTimeGapP95Ms: cadence?.displayTimeGapP95Ms ?? 0,
            displayTimeGapP99Ms: cadence?.displayTimeGapP99Ms ?? 0,
            topologyLimitReason: diagnostics.cadenceLimitReason
        )
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

    func performScreenCaptureDeliveryRecovery(
        _ action: ScreenCaptureDeliveryRecovery.Action,
        telemetry: CaptureStreamOutput.TelemetrySnapshot?
    ) async {
        guard action != .none else { return }

        let diagnostics = VirtualDisplayTopologyDiagnostics.snapshot(
            targetFrameRate: currentFrameRate,
            virtualDisplayID: virtualDisplayContext?.displayID
        )
        diagnostics.log(streamID: streamID)

        let sampleText = screenCaptureDeliverySampleText(telemetry)
        switch action {
        case .none:
            return
        case let .retryNativeMinimumFrameInterval(reason):
            MirageLogger.capture(
                "event=sck_delivery_validation action=retry_native_minimum_frame_interval " +
                    "stream=\(streamID) target=\(currentFrameRate)fps reason=\(reason) \(sampleText)"
            )
            await captureEngine?.retryNativeMinimumFrameIntervalForDeliveryValidation(
                reason: "sck delivery validation native retry"
            )
        case let .restartStrengthenedKeepalive(reason):
            MirageLogger.capture(
                "event=sck_delivery_validation action=restart_strengthened_keepalive " +
                    "stream=\(streamID) target=\(currentFrameRate)fps reason=\(reason) \(sampleText)"
            )
            if let snapshot = await SharedVirtualDisplayManager.shared.restartCadenceDriver(
                for: .desktopStream,
                strength: .strengthened
            ) {
                virtualDisplayContext = snapshot
                updateWindowCaptureVirtualDisplayState(snapshot)
            } else if let snapshot = virtualDisplayContext {
                await MainActor.run {
                    VirtualDisplayKeepaliveController.shared.restart(
                        displayID: snapshot.displayID,
                        spaceID: snapshot.spaceID,
                        refreshRate: snapshot.refreshRate,
                        strength: .strengthened
                    )
                }
            }
            await restartDisplayCaptureForDeliveryValidation(reason: "sck delivery validation keepalive retry")
        case let .downgradeFrameRate(fps, reason):
            MirageLogger.capture(
                "event=sck_delivery_validation action=downgrade_stream_fps " +
                    "stream=\(streamID) target=\(currentFrameRate)fps stableFPS=\(fps) " +
                    "reason=\(reason) \(sampleText)"
            )
            do {
                try await downgradeFrameRateForCaptureDelivery(to: fps, reason: reason)
            } catch {
                MirageLogger.error(.capture, error: error, message: "SCK delivery validation frame-rate downgrade failed: ")
            }
        }
    }

    private func restartDisplayCaptureForDeliveryValidation(reason: String) async {
        guard captureMode == .display, !isResizing, !encodingSuspendedForResize else { return }
        let restarted = await captureEngine?.restartCaptureForDeliveryValidation(reason: reason) ?? false
        guard restarted else { return }
        await scheduleCoalescedRecoveryKeyframe(
            reason: "SCK delivery validation",
            noteLoss: true,
            ignoreExistingInFlight: true
        )
    }

    private func downgradeFrameRateForCaptureDelivery(to fps: Int, reason: String) async throws {
        let clamped = max(1, min(currentFrameRate, fps))
        guard clamped < currentFrameRate else { return }
        try await updateFrameRate(clamped)
        MirageLogger.capture(
            "event=sck_delivery_validation action=downgrade_stream_fps result=applied " +
                "stream=\(streamID) applied=\(clamped)fps reason=\(reason)"
        )
    }

    private func screenCaptureDeliverySampleText(_ telemetry: CaptureStreamOutput.TelemetrySnapshot?) -> String {
        guard let telemetry else { return "sample=unavailable" }
        func fpsText(_ value: Double?) -> String {
            value.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "--"
        }
        let durationText = telemetry.sampleDurationSeconds.formatted(.number.precision(.fractionLength(2)))
        let p50Text = telemetry.cadenceMetrics.displayTimeGapP50Ms.formatted(.number.precision(.fractionLength(1)))
        let p95Text = telemetry.cadenceMetrics.displayTimeGapP95Ms.formatted(.number.precision(.fractionLength(1)))
        let p99Text = telemetry.cadenceMetrics.displayTimeGapP99Ms.formatted(.number.precision(.fractionLength(1)))
        return "duration=\(durationText)s " +
            "raw=\(telemetry.rawScreenCallbackCount)(\(fpsText(telemetry.rawScreenCallbackFPS))fps) " +
            "complete=\(telemetry.completeFrameCount)(\(fpsText(telemetry.completeFrameFPS))fps) " +
            "renderable=\(telemetry.renderableScreenSampleCount)(\(fpsText(telemetry.renderableFrameFPS))fps) " +
            "idle=\(telemetry.idleFrameCount) " +
            "admitted=\(telemetry.cadenceAdmittedFrameCount)(\(fpsText(telemetry.cadenceAdmittedFrameFPS))fps) " +
            "displayTimeGapMs[p50=\(p50Text) p95=\(p95Text) p99=\(p99Text)]"
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
            let now = CFAbsoluteTimeGetCurrent()
            guard !captureRestartShouldWaitForActiveRecovery(now: now) else {
                MirageLogger.capture(
                    "event=capture_cadence_recovery action=restart_capture result=skipped_active_keyframe_recovery stream=\(streamID)"
                )
                return
            }
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

extension StreamContext {
    func captureRestartShouldWaitForActiveRecovery(now: CFAbsoluteTime) -> Bool {
        suppressEncodedNonKeyframesUntilKeyframe ||
            frameChainSuppressesPFrames ||
            isKeyframeEncoding ||
            pendingKeyframeReason != nil ||
            pendingKeyframeDeadline > now ||
            keyframeSendDeadline > now
    }

    func prepareForCaptureRestartRecoveryKeyframe() async {
        let emergencyQuality = emergencyKeyframeQuality()
        pendingEmergencyKeyframeQuality = emergencyQuality
        await encoder?.prepareForKeyframe(quality: emergencyQuality)
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
