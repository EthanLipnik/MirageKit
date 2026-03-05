//
//  HostPointerStallCoalescingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Coverage for host-side stall-window pointer coalescing.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host Pointer Stall Coalescing")
struct HostPointerStallCoalescingTests {
    @Test("Move/drag coalescing is active only inside stall windows")
    func coalescingIsActiveOnlyInsideStallWindow() {
        let registry = HostStreamRegistry()
        let streamID: StreamID = 801

        registry.registerPointerCoalescingRoute(streamID: streamID)
        registry.noteCaptureStallStage(streamID: streamID, stage: .soft, now: 100)

        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 100.000))
        #expect(registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 100.005))
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 100.020))

        // Soft window is 1.2s; after expiry no coalescing should be applied.
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 101.250))
    }

    @Test("Resumed signal keeps coalescing briefly then expires")
    func resumedSignalKeepsShortTailWindow() {
        let registry = HostStreamRegistry()
        let streamID: StreamID = 802

        registry.registerPointerCoalescingRoute(streamID: streamID)
        registry.noteCaptureStallStage(streamID: streamID, stage: .hard, now: 200)
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 200.000))

        registry.noteCaptureStallStage(streamID: streamID, stage: .resumed, now: 200.100)
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 200.108))
        #expect(registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 200.112))
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 200.520))
    }

    @Test("Unregistered streams bypass pointer coalescing")
    func unregisteredStreamsBypassCoalescing() {
        let registry = HostStreamRegistry()
        let streamID: StreamID = 803

        registry.noteCaptureStallStage(streamID: streamID, stage: .hard, now: 300)
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 300.010))

        registry.registerPointerCoalescingRoute(streamID: streamID)
        registry.unregisterPointerCoalescingRoute(streamID: streamID)
        registry.noteCaptureStallStage(streamID: streamID, stage: .soft, now: 300)
        #expect(!registry.shouldCoalesceDesktopPointerEvent(streamID: streamID, now: 300.020))
    }
}
#endif
