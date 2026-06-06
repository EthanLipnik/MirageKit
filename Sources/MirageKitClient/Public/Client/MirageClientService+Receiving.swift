//
//  MirageClientService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  TCP control message receiving and buffering.
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
import Network

private final class ClientControlPingFastPath: @unchecked Sendable {
    private var receiveBuffer = Data()

    func inspect(_ data: Data, respondOn controlChannel: MirageControlChannel) {
        receiveBuffer.append(data)

        var parseOffset = 0
        while true {
            switch MirageWire.ControlMessage.deserialize(from: receiveBuffer, offset: parseOffset) {
            case let .success(message, bytesConsumed):
                parseOffset += bytesConsumed
                if message.type == .ping {
                    controlChannel.sendBestEffort(.pong)
                }
            case .needMoreData:
                if parseOffset > 0 {
                    receiveBuffer.removeSubrange(0 ..< parseOffset)
                } else if receiveBuffer.count > MirageControlMessageLimits.maxReceiveBufferBytes {
                    receiveBuffer.removeAll(keepingCapacity: false)
                }
                return
            case .invalidFrame:
                receiveBuffer.removeAll(keepingCapacity: false)
                return
            }
        }
    }
}

@MainActor
extension MirageClientService {
    func startReceiving() {
        guard let controlChannel else { return }

        let serviceBox = WeakSendableBox(self)
        let pingFastPath = ClientControlPingFastPath()
        Task.detached(priority: .userInitiated) { [controlChannel, serviceBox] in
            for await data in controlChannel.incomingBytes {
                guard !Task.isCancelled else { return }
                guard let service = serviceBox.value else { return }
                guard await service.controlChannel === controlChannel else { return }
                if !data.isEmpty {
                    pingFastPath.inspect(data, respondOn: controlChannel)
                    await service.handleIncomingControlChunk(
                        data,
                        for: controlChannel
                    )
                }
            }

            guard let service = serviceBox.value else { return }
            await service.handleControlChannelClosure(controlChannel)
        }
        if !receiveBuffer.isEmpty {
            Task { @MainActor [weak self] in
                await self?.processReceivedData()
            }
        }
    }

    func processReceivedData() async {
        guard !isProcessingReceivedData else { return }
        isProcessingReceivedData = true
        defer { isProcessingReceivedData = false }

        while !receiveBuffer.isEmpty {
            guard case .connected = connectionState else {
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

            switch MirageWire.ControlMessage.deserialize(from: receiveBuffer, offset: 0) {
            case let .success(message, bytesConsumed):
                receiveBuffer.removeSubrange(0 ..< bytesConsumed)
                if controlUpdatePolicy == .interactiveStreaming,
                   Self.shouldDropNonEssentialControlMessageWhileInteractive(message.type) {
                    recordSuppressedControlMessage(message.type)
                    continue
                }
                recordHighFrequencyControlMessageSampleIfNeeded(message.type)
                if Self.shouldLogControlMessage(message.type) {
                    MirageLogger.client("Received message type: \(message.type)")
                }
                await routeControlMessage(message)
            case .needMoreData:
                if receiveBuffer.count > MirageControlMessageLimits.maxReceiveBufferBytes {
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

    private func dropBufferedControlMessagesAfterConnectionStateChange() {
        let bufferedByteCount = receiveBuffer.count
        guard bufferedByteCount > 0 else { return }
        let connectionStateName = switch connectionState {
        case .disconnected:
            "disconnected"
        case .connecting:
            "connecting"
        case .reconnecting:
            "reconnecting"
        case .handshaking:
            "handshaking"
        case .connected:
            "connected"
        case .error:
            "error"
        }
        MirageLogger.client(
            "Dropping \(bufferedByteCount) buffered control bytes because connection state is now \(connectionStateName)"
        )
        receiveBuffer.removeAll(keepingCapacity: false)
    }

    nonisolated static func shouldDropNonEssentialControlMessageWhileInteractive(_ type: MirageWire.ControlMessageType) -> Bool {
        switch type {
        case .appListProgress,
             .appListComplete,
             .hostHardwareIcon,
             .windowList,
             .windowUpdate,
             .hostSoftwareUpdateStatus:
            true
        default:
            false
        }
    }

    private func recordSuppressedControlMessage(_ type: MirageWire.ControlMessageType) {
        switch type {
        case .appListProgress, .appListComplete:
            deferredControlRefreshRequirements.needsAppListRefresh = true
        case .windowList, .windowUpdate:
            deferredControlRefreshRequirements.needsWindowListRefresh = true
        case .hostSoftwareUpdateStatus:
            deferredControlRefreshRequirements.needsHostSoftwareUpdateRefresh = true
        default:
            break
        }
    }

    private func recordHighFrequencyControlMessageSampleIfNeeded(_ type: MirageWire.ControlMessageType) {
        guard MirageSteadyStateDiagnostics.isEnabled else { return }
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

    nonisolated static func shouldLogControlMessage(_ type: MirageWire.ControlMessageType) -> Bool {
        switch type {
        case .appListProgress,
             .cursorUpdate,
             .cursorPositionUpdate,
             .hostSoftwareUpdateStatus,
             .ping,
             .pong,
             .streamMetricsUpdate:
            false
        default:
            true
        }
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
