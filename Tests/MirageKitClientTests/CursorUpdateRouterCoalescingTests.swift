//
//  CursorUpdateRouterCoalescingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Coverage for coalesced cursor update routing and control-log suppression.
//

@testable import MirageKitClient
import MirageKit
import Foundation
import Testing

#if os(macOS)
@Suite("Cursor Update Router Coalescing")
struct CursorUpdateRouterCoalescingTests {
    @Test("Rapid notify burst is coalesced and latest state wins")
    func rapidNotifyBurstIsCoalesced() async throws {
        let streamID: StreamID = 42
        let burstCount = 1_000
        let sequence = SharedSequence()
        let router = MirageCursorUpdateRouter.makeForTesting(
            flushInterval: MirageInteractionCadence.frameInterval120Duration
        )
        let probe = await MainActor.run {
            CursorRefreshProbe(sequenceSource: sequence)
        }
        await MainActor.run {
            router.register(view: probe, for: streamID)
        }
        defer {
            Task { @MainActor in
                router.unregister(streamID: streamID)
            }
        }

        for index in 1 ... burstCount {
            sequence.store(index)
            router.notify(streamID: streamID)
        }

        let deadline = CFAbsoluteTimeGetCurrent() + 2.0
        while CFAbsoluteTimeGetCurrent() < deadline {
            let lastSeen = await MainActor.run { probe.lastSeenSequence }
            if lastSeen == burstCount { break }
            try await Task.sleep(for: .milliseconds(5))
        }

        let refreshCount = await MainActor.run { probe.refreshCount }
        let lastSeenSequence = await MainActor.run { probe.lastSeenSequence }
        let forcedRefreshCount = await MainActor.run { probe.forcedRefreshCount }

        #expect(lastSeenSequence == burstCount)
        #expect(refreshCount > 0)
        #expect(refreshCount < burstCount / 10)
        #expect(forcedRefreshCount == 0)
    }

    @Test("High-frequency cursor control messages are excluded from receive logging")
    func highFrequencyCursorControlMessagesAreExcludedFromReceiveLogging() {
        #expect(!MirageClientService.shouldLogControlMessage(.cursorUpdate))
        #expect(!MirageClientService.shouldLogControlMessage(.cursorPositionUpdate))
        #expect(!MirageClientService.shouldLogControlMessage(.streamMetricsUpdate))
        #expect(MirageClientService.shouldLogControlMessage(.sessionBootstrapResponse))
    }
}

private final class SharedSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func store(_ newValue: Int) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func load() -> Int {
        lock.lock()
        let current = value
        lock.unlock()
        return current
    }
}

@MainActor
private final class CursorRefreshProbe: MirageCursorUpdateHandling {
    private let sequenceSource: SharedSequence
    private(set) var refreshCount: Int = 0
    private(set) var lastSeenSequence: Int = 0
    private(set) var forcedRefreshCount: Int = 0

    init(sequenceSource: SharedSequence) {
        self.sequenceSource = sequenceSource
    }

    func refreshCursorUpdates(force: Bool) {
        refreshCount += 1
        if force {
            forcedRefreshCount += 1
        }
        lastSeenSequence = sequenceSource.load()
    }
}
#endif
