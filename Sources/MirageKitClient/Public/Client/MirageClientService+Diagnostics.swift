//
//  MirageClientService+Diagnostics.swift
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
#if canImport(Darwin)
import Darwin
#endif
import Foundation

extension MirageClientService {
    /// Registers a diagnostics provider for the current client state.
    func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await MirageDiagnosticsContextRegistry.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.diagnosticsContextSnapshot }
            }
        }
    }

    /// Point-in-time client diagnostics emitted with diagnostics reports.
    var diagnosticsContextSnapshot: MirageDiagnosticsContext {
        let primaryStreamID = desktopStreamID ?? activeStreams.first?.id
        let primaryAppStream = primaryStreamID.flatMap { primaryStreamID in
            activeStreams.first { stream in
                stream.id == primaryStreamID || stream.mediaStreamID == primaryStreamID
            }
        }
        let primaryLogicalAcknowledgement = primaryAppStream.flatMap {
            appStreamStartAcknowledgementByStreamID[$0.id]
        }
        let primaryMediaAcknowledgement = primaryAppStream.flatMap {
            appStreamStartAcknowledgementByStreamID[$0.mediaStreamID]
        }
        let primarySnapshot = primaryStreamID.flatMap { metricsStore.snapshot(for: $0) }
        let processPhysicalFootprintBytes = Self.processPhysicalFootprintBytes
        let selectedControlAttempt = recentControlSessionAttemptSummaries.reversed().first { summary in
            summary.phase == "succeeded" || summary.phase == "winner"
        }
        return [
            "client.connectionState": .string(Self.diagnosticsConnectionStateName(connectionState)),
            "client.authorizationState": .string(authorizationState.rawValue),
            "client.awaitingManualApproval": .bool(isAwaitingManualApproval),
            "client.mediaPayloadEncryptionEnabled": .bool(mediaPayloadEncryptionEnabled),
            "client.availableWindowsCount": .int(availableWindows.count),
            "client.activeStreamsCount": .int(activeStreams.count),
            "client.availableAppsCount": .int(availableApps.count),
            "client.hasReceivedWindowList": .bool(hasReceivedWindowList),
            "client.hasReceivedAppList": .bool(hasReceivedAppList),
            "client.desktopStreamActive": .bool(desktopStreamID != nil),
            "client.maxRefreshRateOverride": maxRefreshRateOverride.map(MirageDiagnosticsValue.int) ?? .null,
            "client.memoryPressureCount": .int(runtimeWorkloadSafetyMemoryPressureCount),
            "client.memoryPressureLastAgeSeconds": runtimeWorkloadSafetyLastMemoryPressureTime
                .map { MirageDiagnosticsValue.double(max(0, CFAbsoluteTimeGetCurrent() - $0)) } ?? .null,
            "client.runtimeWorkloadFrameRateCap": runtimeWorkloadSafetyEffectiveFrameRateCap
                .map(MirageDiagnosticsValue.int) ?? .null,
            "client.runtimeWorkloadFallbackReason": runtimeWorkloadSafetyLastFallbackReason.map(MirageDiagnosticsValue.string) ?? .null,
            "client.hostSessionState": hostSessionAvailability.map { .string($0.rawValue) } ?? .null,
            "client.debugRouteOverride": debugRouteOverride.map { .string($0.displayName) } ?? .null,
            "client.debugRouteOverride.transport": debugRouteOverride.map { .string($0.transportKind.rawValue) } ?? .null,
            "client.debugRouteOverride.interfaceName": debugRouteOverride?.interfaceName.map(MirageDiagnosticsValue.string) ?? .null,
            "client.debugRouteOverride.interfaceKind": debugRouteOverride?.interfaceKind.map { .string($0.rawValue) } ?? .null,
            "client.control.selectedAttemptID": selectedControlAttempt?.connectionAttemptID.map(MirageDiagnosticsValue.string) ?? .null,
            "client.control.selectedTransport": selectedControlAttempt.map { .string($0.transport) } ?? .null,
            "client.control.selectedInterface": selectedControlAttempt.map { .string($0.requiredInterface) } ?? .null,
            "client.control.selectedRouteTier": selectedControlAttempt.map { .string($0.routeTier) } ?? .null,
            "client.control.selectedEndpointSource": selectedControlAttempt.map { .string($0.endpointSource) } ?? .null,
            "client.primaryStreamID": primaryStreamID.map { .int(Int($0)) } ?? .null,
            "client.primaryAppStream.logicalStreamID": primaryAppStream.map { .int(Int($0.id)) } ?? .null,
            "client.primaryAppStream.mediaStreamID": primaryAppStream.map { .int(Int($0.mediaStreamID)) } ?? .null,
            "client.primaryAppStream.logicalAcknowledgement": diagnosticsAcknowledgementSize(
                primaryLogicalAcknowledgement
            ),
            "client.primaryAppStream.mediaAcknowledgement": diagnosticsAcknowledgementSize(
                primaryMediaAcknowledgement
            ),
            "client.primaryStream.decoderOutputPixelFormat": primarySnapshot?.clientDecoderOutputPixelFormat.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.decoderHardwareAcceleration": diagnosticsHardwareAccelerationState(
                primarySnapshot?.clientUsingHardwareDecoder
            ),
            "client.primaryStream.reassemblerPendingFrameCount": primarySnapshot
                .map { MirageDiagnosticsValue.int($0.clientReassemblerPendingFrameCount) } ?? .null,
            "client.primaryStream.reassemblerPendingKeyframeCount": primarySnapshot
                .map { MirageDiagnosticsValue.int($0.clientReassemblerPendingKeyframeCount) } ?? .null,
            "client.primaryStream.reassemblerPendingBytes": primarySnapshot
                .map { MirageDiagnosticsValue.int($0.clientReassemblerPendingBytes) } ?? .null,
            "client.primaryStream.frameBufferPoolRetainedBytes": primarySnapshot
                .map { MirageDiagnosticsValue.int($0.clientFrameBufferPoolRetainedBytes) } ?? .null,
            "client.primaryStream.reassemblerBudgetEvictions": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientReassemblerBudgetEvictions)) } ?? .null,
            "client.primaryStream.reassemblerIncompleteFrameTimeouts": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientReassemblerIncompleteFrameTimeouts)) } ?? .null,
            "client.primaryStream.reassemblerMissingFragmentTimeouts": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientReassemblerMissingFragmentTimeouts)) } ?? .null,
            "client.primaryStream.reassemblerFECRecoveredFragmentCount": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientReassemblerFECRecoveredFragmentCount)) } ?? .null,
            "client.primaryStream.pendingFrameNotReadyDisplayTickCount": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientPendingFrameNotReadyDisplayTickCount)) } ?? .null,
            "client.process.physicalFootprintBytes": processPhysicalFootprintBytes
                .map { MirageDiagnosticsValue.int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostEncoderHardwareAcceleration": diagnosticsHardwareAccelerationState(
                primarySnapshot?.hostUsingHardwareEncoder
            ),
            "client.primaryStream.receivedWorstGapMs": primarySnapshot
                .map { MirageDiagnosticsValue.double($0.clientReceivedWorstGapMs) } ?? .null,
            "client.primaryStream.receivedFrameIntervalP95Ms": primarySnapshot
                .map { MirageDiagnosticsValue.double($0.clientReceivedFrameIntervalP95Ms) } ?? .null,
            "client.primaryStream.receivedFrameIntervalP99Ms": primarySnapshot
                .map { MirageDiagnosticsValue.double($0.clientReceivedFrameIntervalP99Ms) } ?? .null,
            "client.primaryStream.hostSendStartDelayMaxMs": primarySnapshot?.hostSendStartDelayMaxMs.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSendCompletionMaxMs": primarySnapshot?.hostSendCompletionMaxMs.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostRealtimeBitrateCeiling": primarySnapshot?.hostRealtimeBitrateCeiling.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostRealtimePressureState": primarySnapshot?.hostRealtimePressureState.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.hostRealtimePressureReason": primarySnapshot?.hostRealtimePressureReason.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.hostAwdlPolicyState": primarySnapshot?.hostAwdlPolicyState.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.hostAwdlPolicyTrigger": primarySnapshot?.hostAwdlPolicyTrigger.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.hostAwdlSelectedLever": primarySnapshot?.hostAwdlSelectedLever.map(MirageDiagnosticsValue.string) ?? .null,
            "client.primaryStream.hostAwdlPlayoutDelayMs": primarySnapshot?.hostAwdlPlayoutDelayMs.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostAwdlResolutionScale": primarySnapshot?.hostAwdlResolutionScale.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostAwdlQualityReductionAllowed": primarySnapshot?.hostAwdlQualityReductionAllowed.map(MirageDiagnosticsValue.bool) ?? .null,
            "client.primaryStream.hostAwdlPacingBudgetBps": primarySnapshot?.hostAwdlPacingBudgetBps.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostPacketPacerTotalSleepMs": primarySnapshot?.hostPacketPacerTotalSleepMs.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostPacketPacerMaxSleepMs": primarySnapshot?.hostPacketPacerMaxSleepMs.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostPacketPacerFrameMaxSleepMs": primarySnapshot?.hostPacketPacerFrameMaxSleepMs.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostMediaPacketSize": primarySnapshot?.hostMediaMaxPacketSize.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostSenderLocalDeadlineDrops": primarySnapshot?.hostSenderLocalDeadlineDrops.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableDeadlineExpiredDrops": primarySnapshot?.hostQueuedUnreliableDropCounts.map { .int(Int(clamping: $0.deadlineExpired)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableQueueLimitDrops": primarySnapshot?.hostQueuedUnreliableDropCounts.map { .int(Int(clamping: $0.queueLimit)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableSupersededDrops": primarySnapshot?.hostQueuedUnreliableDropCounts.map { .int(Int(clamping: $0.superseded)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableUnsupportedTransportDrops": primarySnapshot?.hostQueuedUnreliableDropCounts.map { .int(Int(clamping: $0.unsupportedTransport)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableClosedDrops": primarySnapshot?.hostQueuedUnreliableDropCounts.map { .int(Int(clamping: $0.closed)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableDropCount": .int(Int(clamping: primarySnapshot?.hostQueuedUnreliableDropCounts?.total ?? 0)),
            "client.primaryStream.hostQueuedUnreliablePendingPackets": primarySnapshot?.hostQueuedUnreliablePendingPackets.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliableOutstandingPackets": primarySnapshot?.hostQueuedUnreliableOutstandingPackets.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliableQueuedBytes": primarySnapshot?.hostQueuedUnreliableQueuedBytes.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliablePendingPacketMax": primarySnapshot?.hostQueuedUnreliablePendingPacketMax.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliableOutstandingPacketMax": primarySnapshot?.hostQueuedUnreliableOutstandingPacketMax.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliableQueuedBytesMax": primarySnapshot?.hostQueuedUnreliableQueuedBytesMax.map(MirageDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostQueuedUnreliableEnqueuedCount": primarySnapshot?.hostQueuedUnreliableEnqueuedCount.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableSentCount": primarySnapshot?.hostQueuedUnreliableSentCount.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableCompletedCount": primarySnapshot?.hostQueuedUnreliableCompletedCount.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableDroppedCount": primarySnapshot?.hostQueuedUnreliableDroppedCount.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableErrorCount": primarySnapshot?.hostQueuedUnreliableErrorCount.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostQueuedUnreliableQueueDwellP99Ms": primarySnapshot?.hostQueuedUnreliableQueueDwellP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostQueuedUnreliableSendGapP99Ms": primarySnapshot?.hostQueuedUnreliableSendGapP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostQueuedUnreliableContentProcessedP99Ms": primarySnapshot?.hostQueuedUnreliableContentProcessedP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostTransportPressureDropCount": .int(
                Int(clamping: (primarySnapshot?.hostStalePacketDrops ?? 0) +
                    (primarySnapshot?.hostSenderLocalDeadlineDrops ?? 0) +
                    (primarySnapshot?.hostQueuedUnreliableDropCounts?.total ?? 0))
            ),
            "client.primaryStream.smoothestTargetDelayMs": primarySnapshot
                .map { MirageDiagnosticsValue.double($0.clientSmoothestTargetDelayMs) } ?? .null,
            "client.primaryStream.smoothestUnderflows": primarySnapshot
                .map { MirageDiagnosticsValue.int(Int(clamping: $0.clientSmoothestUnderflowCount)) } ?? .null,
            "client.primaryStream.hostCaptureDeliveredGapP99Ms": primarySnapshot?.hostCaptureDeliveredFrameGapP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureDeliveredGapWorstMs": primarySnapshot?.hostCaptureDeliveredFrameGapWorstMs.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureWallGapP99Ms": primarySnapshot?.hostCaptureWallClockGapP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureDisplayTimeGapP99Ms": primarySnapshot?.hostCaptureDisplayTimeGapP99Ms.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKObservedFPS": primarySnapshot?.hostObservedSCKFPS.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKRawCallbackFPS": primarySnapshot?.hostRawScreenCallbackFPS.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKCompleteFrameFPS": primarySnapshot?.hostCompleteFrameFPS.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKCadenceAdmittedFPS": primarySnapshot?.hostCadenceAdmittedFrameFPS.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureLongFrameGaps": primarySnapshot?.hostCaptureLongFrameGapCount.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostCaptureDisplayTimeDrifts": primarySnapshot?.hostCaptureDisplayTimeDriftCount.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostCaptureVirtualTimingSuspect": primarySnapshot?.hostCaptureVirtualDisplayTimingSuspect.map(MirageDiagnosticsValue.bool) ?? .null,
            "client.primaryStream.hostVirtualDisplayID": primarySnapshot?.hostVirtualDisplayID.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostVirtualDisplayRefreshRate": primarySnapshot?.hostVirtualDisplayRefreshRate.map(MirageDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostVirtualDisplayScaleFactor": primarySnapshot?.hostVirtualDisplayScaleFactor.map(MirageDiagnosticsValue.double) ?? .null,
        ]
    }

    /// Encodes optional hardware-acceleration state for diagnostics.
    func diagnosticsHardwareAccelerationState(_ enabled: Bool?) -> MirageDiagnosticsValue {
        guard let enabled else { return .string("unknown") }
        return .string(enabled ? "active" : "software_fallback")
    }

    func diagnosticsAcknowledgementSize(
        _ acknowledgement: StreamStartAcknowledgement?
    ) -> MirageDiagnosticsValue {
        guard let acknowledgement else { return .null }
        let token = acknowledgement.dimensionToken.map(String.init) ?? "nil"
        return .string("\(acknowledgement.width)x\(acknowledgement.height) token=\(token)")
    }

    /// Current process physical footprint, when Darwin task info is available.
    static var processPhysicalFootprintBytes: UInt64? {
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(
                    mach_task_self_,
                    task_flavor_t(TASK_VM_INFO),
                    reboundPointer,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
        #else
        return nil
        #endif
    }

    /// Stable diagnostics label for the client connection state.
    static func diagnosticsConnectionStateName(_ state: ConnectionState) -> String {
        switch state {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .handshaking:
            "handshaking"
        case .connected:
            "connected"
        case .reconnecting:
            "reconnecting"
        case .error:
            "error"
        }
    }

}
