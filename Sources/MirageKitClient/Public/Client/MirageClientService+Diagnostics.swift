//
//  MirageClientService+Diagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

#if canImport(Darwin)
import Darwin
#endif
import Foundation
import Loom

extension MirageClientService {
    /// Registers a Loom diagnostics provider for the current client state.
    func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.diagnosticsContextSnapshot }
            }
        }
    }

    /// Point-in-time client diagnostics emitted with Loom reports.
    var diagnosticsContextSnapshot: LoomDiagnosticsContext {
        let primaryStreamID = desktopStreamID ?? activeStreams.first?.id
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
            "client.maxRefreshRateOverride": maxRefreshRateOverride.map(LoomDiagnosticsValue.int) ?? .null,
            "client.memoryPressureCount": .int(runtimeWorkloadSafetyMemoryPressureCount),
            "client.memoryPressureLastAgeSeconds": runtimeWorkloadSafetyLastMemoryPressureTime
                .map { LoomDiagnosticsValue.double(max(0, CFAbsoluteTimeGetCurrent() - $0)) } ?? .null,
            "client.runtimeWorkloadFrameRateCap": runtimeWorkloadSafetyEffectiveFrameRateCap
                .map(LoomDiagnosticsValue.int) ?? .null,
            "client.runtimeWorkloadFallbackReason": runtimeWorkloadSafetyLastFallbackReason.map(LoomDiagnosticsValue.string) ?? .null,
            "client.hostSessionState": hostSessionState.map { .string(String(describing: $0)) } ?? .null,
            "client.debugRouteOverride": debugRouteOverride.map { .string($0.displayName) } ?? .null,
            "client.debugRouteOverride.transport": debugRouteOverride.map { .string($0.transportKind.rawValue) } ?? .null,
            "client.debugRouteOverride.interfaceName": debugRouteOverride?.interfaceName.map(LoomDiagnosticsValue.string) ?? .null,
            "client.debugRouteOverride.interfaceKind": debugRouteOverride?.interfaceKind.map { .string($0.rawValue) } ?? .null,
            "client.control.selectedTransport": selectedControlAttempt.map { .string($0.transport) } ?? .null,
            "client.control.selectedInterface": selectedControlAttempt.map { .string($0.requiredInterface) } ?? .null,
            "client.control.selectedRouteTier": selectedControlAttempt.map { .string($0.routeTier) } ?? .null,
            "client.control.selectedEndpointSource": selectedControlAttempt.map { .string($0.endpointSource) } ?? .null,
            "client.primaryStreamID": primaryStreamID.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.decoderOutputPixelFormat": primarySnapshot?.clientDecoderOutputPixelFormat.map(LoomDiagnosticsValue.string) ?? .null,
            "client.primaryStream.decoderHardwareAcceleration": diagnosticsHardwareAccelerationState(
                primarySnapshot?.clientUsingHardwareDecoder
            ),
            "client.primaryStream.reassemblerPendingFrameCount": primarySnapshot
                .map { LoomDiagnosticsValue.int($0.clientReassemblerPendingFrameCount) } ?? .null,
            "client.primaryStream.reassemblerPendingKeyframeCount": primarySnapshot
                .map { LoomDiagnosticsValue.int($0.clientReassemblerPendingKeyframeCount) } ?? .null,
            "client.primaryStream.reassemblerPendingBytes": primarySnapshot
                .map { LoomDiagnosticsValue.int($0.clientReassemblerPendingBytes) } ?? .null,
            "client.primaryStream.frameBufferPoolRetainedBytes": primarySnapshot
                .map { LoomDiagnosticsValue.int($0.clientFrameBufferPoolRetainedBytes) } ?? .null,
            "client.primaryStream.reassemblerBudgetEvictions": primarySnapshot
                .map { LoomDiagnosticsValue.int(Int(clamping: $0.clientReassemblerBudgetEvictions)) } ?? .null,
            "client.primaryStream.reassemblerIncompleteFrameTimeouts": primarySnapshot
                .map { LoomDiagnosticsValue.int(Int(clamping: $0.clientReassemblerIncompleteFrameTimeouts)) } ?? .null,
            "client.primaryStream.reassemblerMissingFragmentTimeouts": primarySnapshot
                .map { LoomDiagnosticsValue.int(Int(clamping: $0.clientReassemblerMissingFragmentTimeouts)) } ?? .null,
            "client.process.physicalFootprintBytes": processPhysicalFootprintBytes
                .map { LoomDiagnosticsValue.int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.hostEncoderHardwareAcceleration": diagnosticsHardwareAccelerationState(
                primarySnapshot?.hostUsingHardwareEncoder
            ),
            "client.primaryStream.receivedWorstGapMs": primarySnapshot
                .map { LoomDiagnosticsValue.double($0.clientReceivedWorstGapMs) } ?? .null,
            "client.primaryStream.receivedFrameIntervalP95Ms": primarySnapshot
                .map { LoomDiagnosticsValue.double($0.clientReceivedFrameIntervalP95Ms) } ?? .null,
            "client.primaryStream.receivedFrameIntervalP99Ms": primarySnapshot
                .map { LoomDiagnosticsValue.double($0.clientReceivedFrameIntervalP99Ms) } ?? .null,
            "client.primaryStream.hostSendStartDelayMaxMs": primarySnapshot?.hostSendStartDelayMaxMs.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSendCompletionMaxMs": primarySnapshot?.hostSendCompletionMaxMs.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostPacketPacerTotalSleepMs": primarySnapshot?.hostPacketPacerTotalSleepMs.map(LoomDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostPacketPacerMaxSleepMs": primarySnapshot?.hostPacketPacerMaxSleepMs.map(LoomDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostPacketPacerFrameMaxSleepMs": primarySnapshot?.hostPacketPacerFrameMaxSleepMs.map(LoomDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostMediaPacketSize": primarySnapshot?.hostMediaMaxPacketSize.map(LoomDiagnosticsValue.int) ?? .null,
            "client.primaryStream.hostSenderLocalDeadlineDrops": primarySnapshot?.hostSenderLocalDeadlineDrops.map { .int(Int(clamping: $0)) } ?? .null,
            "client.primaryStream.smoothestTargetDelayMs": primarySnapshot
                .map { LoomDiagnosticsValue.double($0.clientSmoothestTargetDelayMs) } ?? .null,
            "client.primaryStream.smoothestUnderflows": primarySnapshot
                .map { LoomDiagnosticsValue.int(Int(clamping: $0.clientSmoothestUnderflowCount)) } ?? .null,
            "client.primaryStream.hostCaptureDeliveredGapP99Ms": primarySnapshot?.hostCaptureDeliveredFrameGapP99Ms.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureDeliveredGapWorstMs": primarySnapshot?.hostCaptureDeliveredFrameGapWorstMs.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureWallGapP99Ms": primarySnapshot?.hostCaptureWallClockGapP99Ms.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureDisplayTimeGapP99Ms": primarySnapshot?.hostCaptureDisplayTimeGapP99Ms.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKObservedFPS": primarySnapshot?.hostObservedSCKFPS.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKRawCallbackFPS": primarySnapshot?.hostRawScreenCallbackFPS.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKCompleteFrameFPS": primarySnapshot?.hostCompleteFrameFPS.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostSCKCadenceAdmittedFPS": primarySnapshot?.hostCadenceAdmittedFrameFPS.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostCaptureLongFrameGaps": primarySnapshot?.hostCaptureLongFrameGapCount.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostCaptureDisplayTimeDrifts": primarySnapshot?.hostCaptureDisplayTimeDriftCount.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostCaptureVirtualTimingSuspect": primarySnapshot?.hostCaptureVirtualDisplayTimingSuspect.map(LoomDiagnosticsValue.bool) ?? .null,
            "client.primaryStream.hostVirtualDisplayID": primarySnapshot?.hostVirtualDisplayID.map { .int(Int($0)) } ?? .null,
            "client.primaryStream.hostVirtualDisplayRefreshRate": primarySnapshot?.hostVirtualDisplayRefreshRate.map(LoomDiagnosticsValue.double) ?? .null,
            "client.primaryStream.hostVirtualDisplayScaleFactor": primarySnapshot?.hostVirtualDisplayScaleFactor.map(LoomDiagnosticsValue.double) ?? .null,
        ]
    }

    /// Encodes optional hardware-acceleration state for diagnostics.
    func diagnosticsHardwareAccelerationState(_ enabled: Bool?) -> LoomDiagnosticsValue {
        guard let enabled else { return .string("unknown") }
        return .string(enabled ? "active" : "software_fallback")
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
