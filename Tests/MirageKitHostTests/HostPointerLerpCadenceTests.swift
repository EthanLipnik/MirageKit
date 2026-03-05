//
//  HostPointerLerpCadenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

@testable import MirageKitHost
import ApplicationServices
import Testing

#if os(macOS)
@Suite("Host Pointer Lerp Cadence")
struct HostPointerLerpCadenceTests {
    @Test("First pointer sample emits immediately")
    func firstSampleEmitsImmediately() {
        #expect(
            MirageHostInputController.shouldEmitPointerUpdateImmediately(
                hasCurrentLocation: false,
                previousEventType: nil,
                nextEventType: .mouseMoved,
                secondsSinceLastSend: 0,
                outputIntervalSeconds: 1.0 / 120.0
            )
        )
    }

    @Test("Pointer event type change emits immediately")
    func eventTypeChangeEmitsImmediately() {
        #expect(
            MirageHostInputController.shouldEmitPointerUpdateImmediately(
                hasCurrentLocation: true,
                previousEventType: .mouseMoved,
                nextEventType: .leftMouseDragged,
                secondsSinceLastSend: 0.001,
                outputIntervalSeconds: 1.0 / 120.0
            )
        )
    }

    @Test("Cadence overrun emits immediately")
    func cadenceOverrunEmitsImmediately() {
        #expect(
            MirageHostInputController.shouldEmitPointerUpdateImmediately(
                hasCurrentLocation: true,
                previousEventType: .mouseMoved,
                nextEventType: .mouseMoved,
                secondsSinceLastSend: 0.010,
                outputIntervalSeconds: 1.0 / 120.0
            )
        )
    }

    @Test("Within cadence budget defers to lerp timer")
    func withinCadenceBudgetDefers() {
        #expect(
            !MirageHostInputController.shouldEmitPointerUpdateImmediately(
                hasCurrentLocation: true,
                previousEventType: .mouseMoved,
                nextEventType: .mouseMoved,
                secondsSinceLastSend: 0.001,
                outputIntervalSeconds: 1.0 / 120.0
            )
        )
    }
}
#endif
