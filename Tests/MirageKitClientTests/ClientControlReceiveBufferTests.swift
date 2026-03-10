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

    @discardableResult
    func increment() -> Int {
        value += 1
        return value
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

    @Test("Reentrant control handlers can append follow-up data without losing the new message")
    func reentrantHandlerCanAppendFollowUpData() async {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let counter = ReceiveCounter()
        let message = ControlMessage(type: .pong)

        await MainActor.run {
            service.controlMessageHandlers[.pong] = { _ in
                let count = await counter.increment()
                guard count == 1 else { return }

                service.receiveBuffer.append(message.serialize())
                await service.processReceivedData()
            }
            service.receiveBuffer = message.serialize()
        }

        await service.processReceivedData()

        let routedCount = await counter.value
        let remainingBufferCount = await MainActor.run { service.receiveBuffer.count }
        #expect(routedCount == 2)
        #expect(remainingBufferCount == 0)
    }
}
