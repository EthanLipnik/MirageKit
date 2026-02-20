//
//  HostReceiveLoopTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Receive-loop backlog/coalescing behavior.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Network
import Testing

@Suite("Host Receive Loop")
struct HostReceiveLoopTests {
    @Test("Input ingress stays live while non-input control dispatch is in flight")
    func inputIngressStaysLiveWhileControlDispatchInFlight() async throws {
        let streamID: StreamID = 7
        let control = try ControlMessage(
            type: .displayResolutionChange,
            content: DisplayResolutionChangeMessage(streamID: streamID, displayWidth: 1280, displayHeight: 720)
        )
        let input = try ControlMessage(
            type: .inputEvent,
            content: InputEventMessage(streamID: streamID, event: .keyDown(MirageKeyEvent(keyCode: 0x00)))
        )

        struct ReceiveEvent {
            var data: Data?
            var isComplete: Bool
            var error: NWError?
        }

        let receiveEvents = Locked([
            ReceiveEvent(data: control.serialize(), isComplete: false, error: nil),
            ReceiveEvent(data: input.serialize(), isComplete: false, error: nil),
            ReceiveEvent(data: nil, isComplete: true, error: nil),
        ])

        let inputCount = Locked(0)
        let controlCount = Locked(0)
        let terminalReason = Locked<HostReceiveLoop.TerminalReason?>(nil)

        let loop = HostReceiveLoop(
            clientName: "unit-test",
            receiveChunk: { completion in
                let next: ReceiveEvent? = receiveEvents.withLock { events in
                    if events.isEmpty { return nil }
                    return events.removeFirst()
                }
                guard let next else {
                    completion(nil, nil, true, nil)
                    return
                }
                completion(next.data, nil, next.isComplete, next.error)
            },
            onInputMessage: { _ in
                inputCount.withLock { $0 += 1 }
            },
            dispatchControlMessage: { _, completion in
                controlCount.withLock { $0 += 1 }
                DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.25) {
                    completion()
                }
            },
            onTerminal: { reason in
                terminalReason.withLock { $0 = reason }
            },
            isFatalError: { _ in false }
        )

        loop.start()

        try await Task.sleep(for: .milliseconds(60))

        #expect(inputCount.read { $0 } == 1)
        #expect(controlCount.read { $0 } == 1)

        let terminalDeadline = CFAbsoluteTimeGetCurrent() + 2.0
        while terminalReason.read({ $0 }) == nil, CFAbsoluteTimeGetCurrent() < terminalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminalReason.read { $0 } != nil)
        let reason = terminalReason.read { $0 }
        guard case .complete? = reason else {
            Issue.record("Expected complete terminal reason, got \(String(describing: reason))")
            return
        }
    }

    @Test("Coalesced messages keep last payload and direct messages keep order")
    func coalescedMessagesKeepLastPayloadAndDirectMessagesKeepOrder() async throws {
        let streamID: StreamID = 11

        let messageA = try ControlMessage(
            type: .displayResolutionChange,
            content: DisplayResolutionChangeMessage(streamID: streamID, displayWidth: 1000, displayHeight: 700)
        )
        let messageScale = try ControlMessage(
            type: .streamScaleChange,
            content: StreamScaleChangeMessage(streamID: streamID, streamScale: 0.75)
        )
        let messageB = try ControlMessage(
            type: .displayResolutionChange,
            content: DisplayResolutionChangeMessage(streamID: streamID, displayWidth: 1920, displayHeight: 1080)
        )
        let messageKeyframe = try ControlMessage(
            type: .keyframeRequest,
            content: KeyframeRequestMessage(streamID: streamID)
        )
        let messageRefresh60 = try ControlMessage(
            type: .streamRefreshRateChange,
            content: StreamRefreshRateChangeMessage(streamID: streamID, maxRefreshRate: 60)
        )
        let messageRefresh120 = try ControlMessage(
            type: .streamRefreshRateChange,
            content: StreamRefreshRateChangeMessage(streamID: streamID, maxRefreshRate: 120)
        )

        var initialData = Data()
        initialData.append(messageA.serialize())
        initialData.append(messageScale.serialize())
        initialData.append(messageB.serialize())
        initialData.append(messageKeyframe.serialize())
        initialData.append(messageRefresh60.serialize())
        initialData.append(messageRefresh120.serialize())

        let dispatched = Locked<[ControlMessage]>([])
        let terminalReason = Locked<HostReceiveLoop.TerminalReason?>(nil)

        let loop = HostReceiveLoop(
            clientName: "coalesce-test",
            receiveChunk: { completion in
                completion(nil, nil, true, nil)
            },
            onInputMessage: { _ in },
            dispatchControlMessage: { message, completion in
                dispatched.withLock { $0.append(message) }
                completion()
            },
            onTerminal: { reason in
                terminalReason.withLock { $0 = reason }
            },
            isFatalError: { _ in false }
        )

        loop.start(initialBuffer: initialData)

        let terminalDeadline = CFAbsoluteTimeGetCurrent() + 2.0
        while terminalReason.read({ $0 }) == nil, CFAbsoluteTimeGetCurrent() < terminalDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(terminalReason.read { $0 } != nil)

        let dispatchedMessages = dispatched.read { $0 }
        #expect(dispatchedMessages.map(\.type) == [
            .displayResolutionChange,
            .streamScaleChange,
            .keyframeRequest,
            .streamRefreshRateChange,
        ])

        let resolvedDisplay = try dispatchedMessages[0].decode(DisplayResolutionChangeMessage.self)
        #expect(resolvedDisplay.displayWidth == 1920)
        #expect(resolvedDisplay.displayHeight == 1080)

        let resolvedRefresh = try dispatchedMessages[3].decode(StreamRefreshRateChangeMessage.self)
        #expect(resolvedRefresh.maxRefreshRate == 120)

        let reason = terminalReason.read { $0 }
        guard case .complete? = reason else {
            Issue.record("Expected complete terminal reason, got \(String(describing: reason))")
            return
        }
    }
}

#endif
