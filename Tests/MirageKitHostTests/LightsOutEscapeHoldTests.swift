//
//  LightsOutEscapeHoldTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//
//  Escape hold matching coverage for Lights Out emergency recovery.
//

#if os(macOS)
@testable import MirageKitHost
import Testing

@Suite("Lights Out Escape hold")
struct LightsOutEscapeHoldTests {
    @Test
    func beginsOnEscapeWhenNotAlreadyHolding() {
        #expect(HostLightsOutController.shouldBeginEscapeHold(keyCode: 0x35, isTracking: false))
    }

    @Test
    func ignoresRepeatedEscapeWhileAlreadyHolding() {
        #expect(!HostLightsOutController.shouldBeginEscapeHold(keyCode: 0x35, isTracking: true))
    }

    @Test
    func ignoresEscapeAfterTriggerUntilKeyUpResetsTracking() {
        #expect(!HostLightsOutController.shouldBeginEscapeHold(keyCode: 0x35, isTracking: true))
    }

    @Test
    func ignoresOtherKeys() {
        #expect(!HostLightsOutController.shouldBeginEscapeHold(keyCode: 0x00, isTracking: false))
    }
}
#endif
