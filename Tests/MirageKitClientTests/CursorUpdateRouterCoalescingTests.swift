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
        let router = MirageCursorUpdateRouter(
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

        try await waitUntil(timeout: .seconds(2)) {
            let lastSeen = await MainActor.run { probe.lastSeenSequence }
            return lastSeen == burstCount
        }

        let refreshCount = await MainActor.run { probe.refreshCount }
        let lastSeenSequence = await MainActor.run { probe.lastSeenSequence }
        let forcedRefreshCount = await MainActor.run { probe.forcedRefreshCount }

        #expect(lastSeenSequence == burstCount)
        #expect(refreshCount > 0)
        #expect(refreshCount < burstCount / 10)
        #expect(forcedRefreshCount == 0)
    }

    @Test("Forced notify survives coalescing and wins over non-forced refreshes")
    func forcedNotifyWinsOverNonForcedRefreshes() async throws {
        let streamID: StreamID = 77
        let sequence = SharedSequence()
        let router = MirageCursorUpdateRouter(
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

        sequence.store(1)
        router.notify(streamID: streamID)
        sequence.store(2)
        router.notify(streamID: streamID, force: true)

        try await waitUntil(timeout: .seconds(2)) {
            let lastSeen = await MainActor.run { probe.lastSeenSequence }
            let forcedCount = await MainActor.run { probe.forcedRefreshCount }
            return lastSeen == 2 && forcedCount > 0
        }

        let lastSeenSequence = await MainActor.run { probe.lastSeenSequence }
        let forcedRefreshCount = await MainActor.run { probe.forcedRefreshCount }

        #expect(lastSeenSequence == 2)
        #expect(forcedRefreshCount == 1)
    }

    @Test("Cursor store and router coalesce to latest cursor shape")
    func cursorStoreAndRouterCoalesceToLatestCursorShape() async throws {
        let streamID: StreamID = 91
        let updateCount = 200
        let store = MirageClientCursorStore()
        let router = MirageCursorUpdateRouter(
            flushInterval: MirageInteractionCadence.frameInterval120Duration
        )
        let probe = await MainActor.run {
            CursorStoreRefreshProbe(store: store, streamID: streamID)
        }
        await MainActor.run {
            router.register(view: probe, for: streamID)
        }
        defer {
            Task { @MainActor in
                router.unregister(streamID: streamID)
            }
        }

        for index in 0 ..< updateCount {
            let cursorType: MirageCursorType = index == updateCount - 1 ? .resizeNWSE : .arrow
            _ = store.updateCursor(streamID: streamID, cursorType: cursorType, isVisible: true)
            router.notify(streamID: streamID)
        }

        try await waitUntil(timeout: .seconds(2)) {
            let cursorType = await MainActor.run { probe.lastCursorType }
            return cursorType == .resizeNWSE
        }

        let refreshCount = await MainActor.run { probe.refreshCount }
        let lastCursorType = await MainActor.run { probe.lastCursorType }
        let lastSequence = await MainActor.run { probe.lastSequence }

        #expect(lastCursorType == .resizeNWSE)
        #expect(lastSequence == 2)
        #expect(refreshCount > 0)
        #expect(refreshCount < updateCount / 10)
    }
}

private func waitUntil(
    timeout: Duration,
    condition: () async -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !Task.isCancelled, ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
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

@MainActor
private final class CursorStoreRefreshProbe: MirageCursorUpdateHandling {
    private let store: MirageClientCursorStore
    private let streamID: StreamID
    private(set) var refreshCount: Int = 0
    private(set) var lastCursorType: MirageCursorType?
    private(set) var lastSequence: UInt64 = 0

    init(store: MirageClientCursorStore, streamID: StreamID) {
        self.store = store
        self.streamID = streamID
    }

    func refreshCursorUpdates(force _: Bool) {
        refreshCount += 1
        guard let snapshot = store.snapshot(for: streamID) else { return }
        lastCursorType = snapshot.cursorType
        lastSequence = snapshot.sequence
    }
}
#endif
