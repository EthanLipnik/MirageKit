//
//  ClientControlReceiveBufferTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/7/26.
//

@testable import MirageKitClient
import Foundation
import Testing

private actor ReceiveCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

@Suite("Client Control Receive Buffer")
struct ClientControlReceiveBufferTests {
    @Test("Reentrant control handlers can clear the receive buffer without leaving a stale parse offset")
    func reentrantHandlerCanClearBuffer() async {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let counter = ReceiveCounter()
        let message = ControlMessage(type: .pong)

        await MainActor.run {
            service.controlMessageHandlers[.pong] = { _ in
                await counter.increment()
                service.receiveBuffer.removeAll(keepingCapacity: false)
            }
            service.receiveBuffer = message.serialize()
        }

        await service.processReceivedData()

        let routedCount = await counter.value
        let remainingBufferCount = await MainActor.run { service.receiveBuffer.count }
        #expect(routedCount == 1)
        #expect(remainingBufferCount == 0)
    }
}
