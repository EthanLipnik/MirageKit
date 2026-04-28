//
//  MirageClientService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  TCP control message receiving and buffering.
//

import Foundation
import Loom
import MirageKit
import Network

@MainActor
extension MirageClientService {
    func startReceiving() {
        guard let controlChannel else { return }

        let serviceBox = WeakSendableBox(self)
        Task.detached(priority: .userInitiated) { [controlChannel, serviceBox] in
            for await data in controlChannel.incomingBytes {
                guard !Task.isCancelled else { return }
                guard let service = serviceBox.value else { return }
                guard await service.isCurrentControlChannel(controlChannel) else { return }
                if !data.isEmpty {
                    await service.handleIncomingControlChunk(
                        data,
                        for: controlChannel
                    )
                }
            }

            guard let service = serviceBox.value else { return }
            await service.handleControlChannelClosure(controlChannel)
        }
    }

    func processReceivedData() async {
        guard !isProcessingReceivedData else { return }
        isProcessingReceivedData = true
        defer { isProcessingReceivedData = false }

        while !receiveBuffer.isEmpty {
            guard shouldContinueProcessingBufferedControlMessages else {
                dropBufferedControlMessagesAfterConnectionStateChange()
                return
            }

            if receiveBuffer.count >= 4, receiveBuffer.prefix(4).elementsEqual([0x4D, 0x49, 0x52, 0x47]) {
                MirageLogger.client("Protocol violation: received video data on TCP control channel")
                receiveBuffer.removeAll(keepingCapacity: false)
                await handleDisconnect(
                    reason: "Invalid control-channel payload",
                    state: .error("Invalid control-channel payload"),
                    notifyDelegate: hasCompletedBootstrap
                )
                return
            }

            switch ControlMessage.deserialize(from: receiveBuffer, offset: 0) {
            case let .success(message, bytesConsumed):
                receiveBuffer.removeSubrange(0 ..< bytesConsumed)
                if shouldDropControlMessageWhileSuppressed(message.type) {
                    recordSuppressedControlMessage(message.type)
                    continue
                }
                recordHighFrequencyControlMessageSampleIfNeeded(message.type)
                if shouldLogReceivedControlMessage(message.type) {
                    MirageLogger.client("Received message type: \(message.type)")
                }
                await routeControlMessage(message)
            case .needMoreData:
                if receiveBuffer.count > LoomMessageLimits.maxReceiveBufferBytes {
                    MirageLogger.client("Control receive buffer overflow (\(receiveBuffer.count) bytes)")
                    receiveBuffer.removeAll(keepingCapacity: false)
                    await handleDisconnect(
                        reason: "Control receive buffer overflow",
                        state: .error("Control receive buffer overflow"),
                        notifyDelegate: hasCompletedBootstrap
                    )
                }
                return
            case let .invalidFrame(reason):
                MirageLogger.client("Protocol violation while parsing control frame: \(reason)")
                receiveBuffer.removeAll(keepingCapacity: false)
                await handleDisconnect(
                    reason: "Invalid control frame",
                    state: .error("Invalid control frame"),
                    notifyDelegate: hasCompletedBootstrap
                )
                return
            }
        }
    }

    private var shouldContinueProcessingBufferedControlMessages: Bool {
        if case .connected = connectionState {
            return true
        }
        return false
    }

    private func dropBufferedControlMessagesAfterConnectionStateChange() {
        let bufferedByteCount = receiveBuffer.count
        guard bufferedByteCount > 0 else { return }
        MirageLogger.client(
            "Dropping \(bufferedByteCount) buffered control bytes because connection state is now \(bufferedControlMessageConnectionStateName)"
        )
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    private var bufferedControlMessageConnectionStateName: String {
        switch connectionState {
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .reconnecting:
            return "reconnecting"
        case .handshaking:
            return "handshaking"
        case .connected:
            return "connected"
        case .error:
            return "error"
        }
    }

    private func shouldDropControlMessageWhileSuppressed(_ type: ControlMessageType) -> Bool {
        guard controlUpdatePolicy == .interactiveStreaming else { return false }
        return Self.shouldDropNonEssentialControlMessageWhileInteractive(type)
    }

    nonisolated static func shouldDropNonEssentialControlMessageWhileInteractive(_ type: ControlMessageType) -> Bool {
        switch type {
        case .appListComplete,
             .appIconUpdate,
             .appIconStreamComplete,
             .hostHardwareIcon,
             .windowList,
             .windowUpdate,
             .hostSoftwareUpdateStatus:
            return true
        default:
            return false
        }
    }

    private func recordSuppressedControlMessage(_ type: ControlMessageType) {
        switch type {
        case .appListComplete, .appIconUpdate, .appIconStreamComplete:
            deferredControlRefreshRequirements.needsAppListRefresh = true
        case .windowList, .windowUpdate:
            deferredControlRefreshRequirements.needsWindowListRefresh = true
        case .hostSoftwareUpdateStatus:
            deferredControlRefreshRequirements.needsHostSoftwareUpdateRefresh = true
        default:
            break
        }

        switch type {
        case .appIconUpdate:
            droppedAppIconUpdateMessagesWhileSuppressed &+= 1
            if droppedAppIconUpdateMessagesWhileSuppressed == 1 ||
                droppedAppIconUpdateMessagesWhileSuppressed % 200 == 0 {
                MirageLogger.client(
                    "Suppressed app icon updates while prioritizing stream input (dropped=\(droppedAppIconUpdateMessagesWhileSuppressed))"
                )
            }
        case .appListComplete, .appIconStreamComplete, .windowList, .windowUpdate, .hostSoftwareUpdateStatus:
            break
        default:
            break
        }
    }

    private func shouldLogReceivedControlMessage(_ type: ControlMessageType) -> Bool {
        Self.shouldLogControlMessage(type)
    }

    private func recordHighFrequencyControlMessageSampleIfNeeded(_ type: ControlMessageType) {
        guard type == .streamMetricsUpdate else { return }
        streamMetricsMessagesSinceLastSample &+= 1

        let now = CFAbsoluteTimeGetCurrent()
        if lastStreamMetricsSampleTime == 0 {
            lastStreamMetricsSampleTime = now
            return
        }
        guard now - lastStreamMetricsSampleTime >= streamMetricsSampleInterval else { return }

        let metricsCount = streamMetricsMessagesSinceLastSample
        streamMetricsMessagesSinceLastSample = 0
        lastStreamMetricsSampleTime = now
        guard metricsCount > 0 else { return }
        MirageLogger.network("Control sample (1s): streamMetricsUpdates=\(metricsCount)")
    }

    private func isExpectedReceiveTermination(_ error: Error) -> Bool {
        Self.isExpectedTransportTermination(error)
    }

    private func shouldTreatReceiveErrorAsDisconnect(_ error: Error) -> Bool {
        if isExpectedReceiveTermination(error) {
            return true
        }

        return hasCompletedBootstrap == false
    }

    nonisolated static func isExpectedTransportTermination(_ error: Error) -> Bool {
        if let nwError = error as? NWError {
            switch nwError {
            case let .posix(code):
                return expectedReceivePOSIXErrors.contains(code)
            default:
                break
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain,
           let code = POSIXErrorCode(rawValue: Int32(nsError.code)) {
            return expectedReceivePOSIXErrors.contains(code)
        }
        if expectedNetworkReceiveErrorDomains.contains(nsError.domain),
           expectedNetworkReceiveErrorCodes.contains(nsError.code) {
            return true
        }

        return false
    }

    private nonisolated static var expectedReceivePOSIXErrors: Set<POSIXErrorCode> {
        [
            .ECONNABORTED,
            .ECONNRESET,
            .ENOTCONN,
            .ETIMEDOUT,
            .ECANCELED,
            .ENETDOWN,
            .ENETUNREACH,
            .ENETRESET,
            .EHOSTUNREACH,
            .EPIPE,
        ]
    }

    private nonisolated static let expectedNetworkReceiveErrorDomains: Set<String> = [
        "Network.NWError",
        "NWErrorDomain",
        "NWError",
        "kNWErrorDomainPOSIX",
    ]

    nonisolated static func shouldLogControlMessage(_ type: ControlMessageType) -> Bool {
        switch type {
        case .appIconUpdate, .cursorUpdate, .cursorPositionUpdate, .streamMetricsUpdate:
            return false
        default:
            return true
        }
    }

    private nonisolated static var expectedNetworkReceiveErrorCodes: Set<Int> {
        [
            89,
        ]
    }

    private func isCurrentControlChannel(_ channel: MirageControlChannel) -> Bool {
        controlChannel === channel
    }

    private func handleIncomingControlChunk(
        _ data: Data,
        for controlChannel: MirageControlChannel
    ) async {
        guard self.controlChannel === controlChannel else { return }
        fastPathState.noteInboundControlActivity()
        receiveBuffer.append(data)
        await processReceivedData()
    }

    private func handleControlChannelClosure(_ controlChannel: MirageControlChannel) async {
        guard self.controlChannel === controlChannel else { return }
        MirageLogger.client("Control stream closed by server")
        await handleDisconnect(
            reason: "Host disconnected",
            state: .disconnected,
            notifyDelegate: hasCompletedBootstrap
        )
    }
}
