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
import CoreGraphics
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
            onPingMessage: { },
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

        try await waitUntil { terminalReason.read { $0 } != nil }
        #expect(terminalReason.read { $0 } != nil)
        let reason = terminalReason.read { $0 }
        guard case .complete? = reason else {
            Issue.record("Expected complete terminal reason, got \(String(describing: reason))")
            return
        }
    }

    @Test("Cancel setup lifecycle signal bypasses in-flight control dispatch")
    func cancelSetupLifecycleSignalBypassesInFlightControlDispatch() async throws {
        let control = try ControlMessage(
            type: .displayResolutionChange,
            content: DisplayResolutionChangeMessage(streamID: 7, displayWidth: 1280, displayHeight: 720)
        )
        let cancel = try ControlMessage(
            type: .cancelStreamSetup,
            content: CancelStreamSetupMessage(startupRequestID: UUID(), kind: .desktop, appSessionID: nil)
        )

        var initialData = Data()
        initialData.append(control.serialize())
        initialData.append(cancel.serialize())

        let dispatchedTypes = Locked<[ControlMessageType]>([])
        let lifecycleTypes = Locked<[ControlMessageType]>([])
        let controlCompletion = Locked<(@Sendable () -> Void)?>(nil)

        let loop = HostReceiveLoop(
            clientName: "cancel-lifecycle-test",
            receiveChunk: { _ in },
            onInputMessage: { _ in },
            onPingMessage: { },
            onLifecycleSignal: { signal in
                if case let .cancelStreamSetup(message) = signal {
                    lifecycleTypes.withLock { $0.append(message.type) }
                }
            },
            dispatchControlMessage: { message, completion in
                dispatchedTypes.withLock { $0.append(message.type) }
                controlCompletion.withLock { $0 = completion }
            },
            onTerminal: { _ in },
            isFatalError: { _ in false }
        )

        loop.start(initialBuffer: initialData)
        try await Task.sleep(for: .milliseconds(40))

        #expect(dispatchedTypes.read { $0 } == [.displayResolutionChange])
        #expect(lifecycleTypes.read { $0 } == [.cancelStreamSetup])

        controlCompletion.read { $0 }?()
    }

    @Test("Stream ready lifecycle signal bypasses in-flight desktop start dispatch")
    func streamReadyLifecycleSignalBypassesInFlightDesktopStartDispatch() async throws {
        let streamID: StreamID = 7
        let start = ControlMessage(type: .startDesktopStream)
        let ready = try ControlMessage(
            type: .streamReady,
            content: StreamReadyMessage(
                streamID: streamID,
                startupAttemptID: UUID(),
                kind: .desktop
            )
        )
        let trailing = try ControlMessage(
            type: .keyframeRequest,
            content: KeyframeRequestMessage(streamID: streamID)
        )

        var readyAndTrailing = Data()
        readyAndTrailing.append(ready.serialize())
        readyAndTrailing.append(trailing.serialize())

        struct ReceiveEvent {
            var data: Data?
            var isComplete: Bool
            var error: NWError?
        }

        let receiveEvents = Locked([
            ReceiveEvent(data: start.serialize(), isComplete: false, error: nil),
            ReceiveEvent(data: readyAndTrailing, isComplete: false, error: nil),
        ])
        let dispatchedTypes = Locked<[ControlMessageType]>([])
        let lifecycleTypes = Locked<[ControlMessageType]>([])
        let startCompletion = Locked<(@Sendable () -> Void)?>(nil)

        let loop = HostReceiveLoop(
            clientName: "stream-ready-lifecycle-test",
            receiveChunk: { completion in
                let next: ReceiveEvent? = receiveEvents.withLock { events in
                    if events.isEmpty { return nil }
                    return events.removeFirst()
                }
                guard let next else { return }
                completion(next.data, nil, next.isComplete, next.error)
            },
            onInputMessage: { _ in },
            onPingMessage: { },
            onLifecycleSignal: { signal in
                if case let .streamReady(message) = signal {
                    lifecycleTypes.withLock { $0.append(message.type) }
                }
            },
            dispatchControlMessage: { message, completion in
                dispatchedTypes.withLock { $0.append(message.type) }
                if message.type == .startDesktopStream {
                    startCompletion.withLock { $0 = completion }
                } else {
                    completion()
                }
            },
            onTerminal: { _ in },
            isFatalError: { _ in false }
        )

        loop.start()

        try await waitUntil { lifecycleTypes.read { $0 } == [.streamReady] }

        #expect(dispatchedTypes.read { $0 } == [.startDesktopStream])
        #expect(lifecycleTypes.read { $0 } == [.streamReady])

        startCompletion.read { $0 }?()

        try await waitUntil { dispatchedTypes.read { $0.contains(.keyframeRequest) } }

        #expect(dispatchedTypes.read { $0 } == [.startDesktopStream, .keyframeRequest])
        loop.stop()
    }

    @Test("Terminal lifecycle signal bypasses in-flight control dispatch")
    func terminalLifecycleSignalBypassesInFlightControlDispatch() async throws {
        let control = try ControlMessage(
            type: .displayResolutionChange,
            content: DisplayResolutionChangeMessage(streamID: 9, displayWidth: 1280, displayHeight: 720)
        )

        struct ReceiveEvent {
            var data: Data?
            var isComplete: Bool
            var error: NWError?
        }

        let receiveEvents = Locked([
            ReceiveEvent(data: control.serialize(), isComplete: false, error: nil),
            ReceiveEvent(data: nil, isComplete: true, error: nil),
        ])
        let dispatchedTypes = Locked<[ControlMessageType]>([])
        let lifecycleTerminalCount = Locked(0)
        let terminalCount = Locked(0)
        let controlCompletion = Locked<(@Sendable () -> Void)?>(nil)

        let loop = HostReceiveLoop(
            clientName: "terminal-lifecycle-test",
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
            onInputMessage: { _ in },
            onPingMessage: { },
            onLifecycleSignal: { signal in
                if case .terminal = signal {
                    lifecycleTerminalCount.withLock { $0 += 1 }
                }
            },
            dispatchControlMessage: { message, completion in
                dispatchedTypes.withLock { $0.append(message.type) }
                controlCompletion.withLock { $0 = completion }
            },
            onTerminal: { _ in
                terminalCount.withLock { $0 += 1 }
            },
            isFatalError: { _ in false }
        )

        loop.start()
        try await Task.sleep(for: .milliseconds(40))

        #expect(dispatchedTypes.read { $0 } == [.displayResolutionChange])
        #expect(lifecycleTerminalCount.read { $0 } == 1)
        #expect(terminalCount.read { $0 } == 1)

        controlCompletion.read { $0 }?()
    }

    @Test("Clipboard updates are an ordering barrier for following input")
    func clipboardUpdatesOrderBeforeFollowingInput() async throws {
        let streamID: StreamID = 9
        let clipboardUpdate = ControlMessage(type: .sharedClipboardUpdate)
        let input = try ControlMessage(
            type: .inputEvent,
            content: InputEventMessage(streamID: streamID, event: .keyDown(MirageKeyEvent(keyCode: 0x09)))
        )

        var initialData = Data()
        initialData.append(clipboardUpdate.serialize())
        initialData.append(input.serialize())

        let inputCount = Locked(0)
        let dispatchedTypes = Locked<[ControlMessageType]>([])
        let controlCompletion = Locked<(@Sendable () -> Void)?>(nil)

        let loop = HostReceiveLoop(
            clientName: "clipboard-order-test",
            receiveChunk: { _ in },
            onInputMessage: { _ in
                inputCount.withLock { $0 += 1 }
            },
            onPingMessage: { },
            dispatchControlMessage: { message, completion in
                dispatchedTypes.withLock { $0.append(message.type) }
                controlCompletion.withLock { $0 = completion }
            },
            onTerminal: { _ in },
            isFatalError: { _ in false }
        )

        loop.start(initialBuffer: initialData)

        try await Task.sleep(for: .milliseconds(60))
        #expect(dispatchedTypes.read { $0 } == [.sharedClipboardUpdate])
        #expect(inputCount.read { $0 } == 0)

        controlCompletion.read { $0 }?()

        try await waitUntil { inputCount.read { $0 } > 0 }

        #expect(inputCount.read { $0 } == 1)
        loop.stop()
    }

    @Test("Input queued behind clipboard is preserved when control backlog is full")
    func clipboardBarrierInputSurvivesFullControlBacklog() async throws {
        let streamID: StreamID = 10
        let clipboardUpdate = ControlMessage(type: .sharedClipboardUpdate)
        let input = try ControlMessage(
            type: .inputEvent,
            content: InputEventMessage(streamID: streamID, event: .mouseDown(
                MirageMouseEvent(button: .left, location: CGPoint(x: 0.5, y: 0.5), clickCount: 1)
            ))
        )

        var initialData = Data()
        initialData.append(clipboardUpdate.serialize())
        for index in 0 ..< 8 {
            let control = try ControlMessage(
                type: .keyframeRequest,
                content: KeyframeRequestMessage(streamID: StreamID(index + 1))
            )
            initialData.append(control.serialize())
        }
        initialData.append(input.serialize())

        let inputCount = Locked(0)
        let controlCompletion = Locked<(@Sendable () -> Void)?>(nil)

        let loop = HostReceiveLoop(
            clientName: "clipboard-input-backlog-test",
            maxControlBacklog: 8,
            receiveChunk: { _ in },
            onInputMessage: { _ in
                inputCount.withLock { $0 += 1 }
            },
            onPingMessage: { },
            dispatchControlMessage: { message, completion in
                if message.type == .sharedClipboardUpdate {
                    controlCompletion.withLock { $0 = completion }
                } else {
                    completion()
                }
            },
            onTerminal: { _ in },
            isFatalError: { _ in false }
        )

        loop.start(initialBuffer: initialData)

        try await Task.sleep(for: .milliseconds(60))
        #expect(inputCount.read { $0 } == 0)

        controlCompletion.read { $0 }?()

        try await waitUntil { inputCount.read { $0 } > 0 }

        #expect(inputCount.read { $0 } == 1)
        loop.stop()
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
            content: StreamRefreshRateChangeMessage(
                streamID: streamID,
                maxRefreshRate: 60,
                forceDisplayRefresh: false
            )
        )
        let messageRefresh120 = try ControlMessage(
            type: .streamRefreshRateChange,
            content: StreamRefreshRateChangeMessage(
                streamID: streamID,
                maxRefreshRate: 120,
                forceDisplayRefresh: false
            )
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
            onPingMessage: { },
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

        try await waitUntil { terminalReason.read { $0 } != nil }
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

    @Test("Pong replies are consumed without entering generic control dispatch")
    func pongRepliesBypassGenericControlDispatch() async throws {
        let pong = ControlMessage(type: .pong)
        let keyframe = try ControlMessage(
            type: .keyframeRequest,
            content: KeyframeRequestMessage(streamID: 42)
        )

        var initialData = Data()
        initialData.append(pong.serialize())
        initialData.append(keyframe.serialize())

        let dispatched = Locked<[ControlMessage]>([])
        let pingCount = Locked(0)
        let terminalReason = Locked<HostReceiveLoop.TerminalReason?>(nil)

        let loop = HostReceiveLoop(
            clientName: "pong-fast-path-test",
            receiveChunk: { completion in
                completion(nil, nil, true, nil)
            },
            onInputMessage: { _ in },
            onPingMessage: {
                pingCount.withLock { $0 += 1 }
            },
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

        try await waitUntil { terminalReason.read { $0 } != nil }
        #expect(terminalReason.read { $0 } != nil)

        #expect(pingCount.read { $0 } == 0)
        #expect(dispatched.read { $0.map(\.type) } == [.keyframeRequest])

        let reason = terminalReason.read { $0 }
        guard case .complete? = reason else {
            Issue.record("Expected complete terminal reason, got \(String(describing: reason))")
            return
        }
    }

}

func waitUntil(
    timeout: Duration = .seconds(2),
    pollInterval: Duration = .milliseconds(10),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: pollInterval)
    }
}

#endif
