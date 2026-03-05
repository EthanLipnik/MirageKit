//
//  CursorMonitorCadenceTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Cursor monitor cadence defaults and change-detection gating.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("Cursor Monitor Cadence")
struct CursorMonitorCadenceTests {
    @Test("120Hz cadence resolves to shared interaction interval")
    func cadenceResolvesToSharedInteractionInterval() {
        let interval = CursorMonitor.normalizedInterval(rate: Double(MirageInteractionCadence.targetFPS120))
        #expect(abs(interval - MirageInteractionCadence.frameInterval120Seconds) < 0.000_001)
    }

    @Test("Invalid cadence values clamp to 1Hz")
    func invalidCadenceValuesClampToOneHertz() {
        let zeroRateInterval = CursorMonitor.normalizedInterval(rate: 0)
        let negativeRateInterval = CursorMonitor.normalizedInterval(rate: -120)

        #expect(zeroRateInterval == 1.0)
        #expect(negativeRateInterval == 1.0)
    }

    @Test("Unchanged cursor state does not trigger a change")
    func unchangedCursorStateDoesNotTriggerAChange() {
        let didChange = CursorMonitor.didCursorStateChange(
            previousType: .arrow,
            previousVisibility: true,
            cursorType: .arrow,
            isVisible: true
        )

        #expect(!didChange)
    }

    @Test("Cursor type or visibility changes trigger updates")
    func cursorTypeOrVisibilityChangesTriggerUpdates() {
        let typeChanged = CursorMonitor.didCursorStateChange(
            previousType: .arrow,
            previousVisibility: true,
            cursorType: .iBeam,
            isVisible: true
        )
        let visibilityChanged = CursorMonitor.didCursorStateChange(
            previousType: .arrow,
            previousVisibility: true,
            cursorType: .arrow,
            isVisible: false
        )

        #expect(typeChanged)
        #expect(visibilityChanged)
    }
}
#endif
