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
                    MirageLogger.error(.client, "Receive error: \(error)")
                    await handleDisconnect(
                        reason: error.localizedDescription,
                        state: .error(error.localizedDescription),
                        notifyDelegate: true
                    )
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
        // Try to parse complete messages from the buffer.
        while !receiveBuffer.isEmpty {
            // Check if this looks like a control message (first byte should be a valid type).
            let firstByte = receiveBuffer[receiveBuffer.startIndex]

            // Check if it might be video data (starts with MIRG magic: 0x4D 0x49 0x52 0x47).
            if firstByte == 0x4D, receiveBuffer.count >= 4 {
                let magic = receiveBuffer.prefix(4)
                if magic.elementsEqual([0x4D, 0x49, 0x52, 0x47]) {
                    MirageLogger.client("Warning: Received video data on TCP control channel, discarding")
                    // Discard this data - it shouldn't be on TCP.
                    receiveBuffer.removeAll()
                    return
                }
            }

            guard let (message, bytesConsumed) = ControlMessage.deserialize(from: receiveBuffer) else {
                // Not enough data for a complete message, or invalid data.
                // App list with icons can be very large (10MB+), so use a generous limit.
                if receiveBuffer.count > 50_000_000 {
                    MirageLogger.client("Buffer overflow with invalid data, clearing")
                    receiveBuffer.removeAll()
                }
                return
            }

            receiveBuffer.removeFirst(bytesConsumed)
            MirageLogger.client("Received message type: \(message.type)")

            Task {
                await handleControlMessage(message)
            }
        }
    }
}
