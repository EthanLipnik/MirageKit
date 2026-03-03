//
//  MirageClientService+Receiving.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  TCP control message receiving and buffering.
//

import Foundation
import MirageKit
import Network

@MainActor
extension MirageClientService {
    func startReceiving() {
        guard let connection else { return }

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let data, !data.isEmpty {
                    receiveBuffer.append(data)
                    processReceivedData()
                }

                if let error {
                    if isExpectedReceiveTermination(error) {
                        MirageLogger.client("Receive loop ended by peer/network: \(error.localizedDescription)")
                        await handleDisconnect(
                            reason: "Host disconnected",
                            state: .disconnected,
                            notifyDelegate: true
                        )
                    } else {
                        MirageLogger.error(.client, error: error, message: "Receive error: ")
                        await handleDisconnect(
                            reason: error.localizedDescription,
                            state: .error(error.localizedDescription),
                            notifyDelegate: true
                        )
                    }
                    return
                }

                if isComplete {
                    MirageLogger.client("Connection closed by server")
                    await handleDisconnect(
                        reason: "Host disconnected",
                        state: .disconnected,
                        notifyDelegate: true
                    )
                    return
                }

                // Continue receiving.
                startReceiving()
            }
        }
    }

    private func processReceivedData() {
        var parseOffset = 0

        while parseOffset < receiveBuffer.count {
            let frameStart = receiveBuffer.index(receiveBuffer.startIndex, offsetBy: parseOffset)
            let remaining = receiveBuffer.count - parseOffset
            let firstByte = receiveBuffer[frameStart]

            // Detect and reject video packets accidentally sent over the control channel.
            if firstByte == 0x4D, remaining >= 4 {
                let magicEnd = receiveBuffer.index(frameStart, offsetBy: 4)
                let magic = receiveBuffer[frameStart ..< magicEnd]
                if magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) {
                    MirageLogger.client("Protocol violation: received video data on TCP control channel")
                    receiveBuffer.removeAll(keepingCapacity: false)
                    Task {
                        await handleDisconnect(
                            reason: "Invalid control-channel payload",
                            state: .error("Invalid control-channel payload"),
                            notifyDelegate: true
                        )
                    }
                    return
                }
            }

            switch ControlMessage.deserialize(from: receiveBuffer, offset: parseOffset) {
            case let .success(message, bytesConsumed):
                parseOffset += bytesConsumed
                MirageLogger.client("Received message type: \(message.type)")
                Task {
                    await routeControlMessage(message)
                }
            case .needMoreData:
                if parseOffset > 0 {
                    receiveBuffer.removeSubrange(0 ..< parseOffset)
                }
                if receiveBuffer.count > MirageControlMessageLimits.maxReceiveBufferBytes {
                    MirageLogger.client("Control receive buffer overflow (\(receiveBuffer.count) bytes)")
                    receiveBuffer.removeAll(keepingCapacity: false)
                    Task {
                        await handleDisconnect(
                            reason: "Control receive buffer overflow",
                            state: .error("Control receive buffer overflow"),
                            notifyDelegate: true
                        )
                    }
                }
                return
            case let .invalidFrame(reason):
                MirageLogger.client("Protocol violation while parsing control frame: \(reason)")
                receiveBuffer.removeAll(keepingCapacity: false)
                Task {
                    await handleDisconnect(
                        reason: "Invalid control frame",
                        state: .error("Invalid control frame"),
                        notifyDelegate: true
                    )
                }
                return
            }
        }

        if parseOffset > 0 {
            receiveBuffer.removeSubrange(0 ..< parseOffset)
        }
    }

    private func isExpectedReceiveTermination(_ error: Error) -> Bool {
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

        return false
    }

    private var expectedReceivePOSIXErrors: Set<POSIXErrorCode> {
        [
            .ECONNABORTED,
            .ECONNRESET,
            .ENOTCONN,
            .ETIMEDOUT,
        ]
    }
}
