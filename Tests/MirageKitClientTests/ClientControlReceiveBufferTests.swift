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
            service.connectionState = .connected(host: "Test Host")
            service.controlMessageHandlers[.pong] = .empty {
                _ = await counter.increment()
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
            service.connectionState = .connected(host: "Test Host")
            service.controlMessageHandlers[.pong] = .empty {
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

    @Test("Buffered control messages are discarded after the client leaves the connected state")
    func bufferedMessagesDropAfterDisconnectStateChange() async {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let counter = ReceiveCounter()
        let message = ControlMessage(type: .pong)

        await MainActor.run {
            service.connectionState = .connected(host: "Test Host")
            service.controlMessageHandlers[.pong] = .empty {
                let count = await counter.increment()
                guard count == 1 else { return }
                service.connectionState = .disconnected
            }
            service.receiveBuffer = message.serialize() + message.serialize()
        }

        await service.processReceivedData()

        let routedCount = await counter.value
        let remainingBufferCount = await MainActor.run { service.receiveBuffer.count }
        #expect(routedCount == 1)
        #expect(remainingBufferCount == 0)
    }

    @Test("Bootstrap tail buffer drains without waiting for another incoming chunk")
    func bootstrapTailBufferDrainsWithoutAnotherIncomingChunk() async throws {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        let counter = ReceiveCounter()
        let bootstrapResponse = ControlMessage(type: .sessionBootstrapResponse)
        let tailMessage = ControlMessage(type: .pong)
        let stream = AsyncStream<Data> { continuation in
            continuation.yield(bootstrapResponse.serialize() + tailMessage.serialize())
            continuation.finish()
        }

        let received = try await service.receiveSingleControlMessage(from: stream)
        #expect(received.type == .sessionBootstrapResponse)

        await MainActor.run {
            service.connectionState = .connected(host: "Test Host")
            service.controlMessageHandlers[.pong] = .empty {
                _ = await counter.increment()
            }
        }
        await service.processReceivedData()

        try await waitUntil("buffered bootstrap tail") {
            await counter.value == 1
        }

        let remainingBufferCount = await MainActor.run { service.receiveBuffer.count }
        #expect(remainingBufferCount == 0)
    }

    private func waitUntil(
        _ label: String,
        timeout: Duration = .seconds(2),
        pollInterval: Duration = .milliseconds(20),
        condition: @escaping @Sendable () async -> Bool
    ) async throws {
        let start = ContinuousClock.now
        while await !condition() {
            if ContinuousClock.now - start > timeout {
                Issue.record("Timed out waiting for \(label)")
                return
            }
            try await Task.sleep(for: pollInterval)
        }
    }
}
