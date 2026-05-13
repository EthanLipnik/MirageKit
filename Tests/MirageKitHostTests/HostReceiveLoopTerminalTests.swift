//
//  HostReceiveLoopTerminalTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Network
import Testing

extension HostReceiveLoopTests {
    @Test("Invalid frame triggers protocol-violation terminal reason")
    func invalidFrameTriggersProtocolViolation() async throws {
        struct ReceiveEvent {
            var data: Data?
            var isComplete: Bool
            var error: NWError?
        }

        var invalidFrame = Data([0x06])
        withUnsafeBytes(of: UInt32(0).littleEndian) { invalidFrame.append(contentsOf: $0) }

        let receiveEvents = Locked([
            ReceiveEvent(data: invalidFrame, isComplete: false, error: nil),
        ])
        let terminalReason = Locked<HostReceiveLoop.TerminalReason?>(nil)

        let loop = HostReceiveLoop(
            clientName: "invalid-frame-test",
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
            dispatchControlMessage: { _, completion in
                completion()
            },
            onTerminal: { reason in
                terminalReason.withLock { $0 = reason }
            },
            isFatalError: { _ in false }
        )

        loop.start()

        try await waitUntil { terminalReason.read { $0 } != nil }

        let reason = terminalReason.read { $0 }
        guard case .protocolViolation? = reason else {
            Issue.record("Expected protocolViolation terminal reason, got \(String(describing: reason))")
            return
        }
    }

    @Test("Receive buffer cap triggers overflow terminal reason")
    func receiveBufferCapTriggersOverflowTerminalReason() async throws {
        struct ReceiveEvent {
            var data: Data?
            var isComplete: Bool
            var error: NWError?
        }

        let receiveEvents = Locked([
            ReceiveEvent(data: Data(repeating: 0x41, count: 9_000), isComplete: false, error: nil),
        ])
        let terminalReason = Locked<HostReceiveLoop.TerminalReason?>(nil)

        let loop = HostReceiveLoop(
            clientName: "buffer-overflow-test",
            maxReceiveBufferBytes: 8 * 1024,
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
            dispatchControlMessage: { _, completion in
                completion()
            },
            onTerminal: { reason in
                terminalReason.withLock { $0 = reason }
            },
            isFatalError: { _ in false }
        )

        loop.start()

        try await waitUntil { terminalReason.read { $0 } != nil }

        let reason = terminalReason.read { $0 }
        guard case let .receiveBufferOverflow(limit)? = reason else {
            Issue.record("Expected receiveBufferOverflow terminal reason, got \(String(describing: reason))")
            return
        }
        #expect(limit == 8 * 1024)
    }
}
#endif
