//
//  HostModifierInjectionDomainTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//
//  Coverage for host keyboard injection domain mapping and modifier transitions.
//

#if os(macOS)
import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Host modifier injection domain")
struct HostModifierInjectionDomainTests {
    @Test("Recovery map includes left and right key codes for sided modifiers")
    func recoveryMapIncludesLeftAndRightKeyCodes() {
        #expect(Set(MirageHostInputController.recoveryKeyCodes(for: .shift)) == Set([0x38, 0x3C]))
        #expect(Set(MirageHostInputController.recoveryKeyCodes(for: .control)) == Set([0x3B, 0x3E]))
        #expect(Set(MirageHostInputController.recoveryKeyCodes(for: .option)) == Set([0x3A, 0x3D]))
        #expect(Set(MirageHostInputController.recoveryKeyCodes(for: .command)) == Set([0x37, 0x36]))
        #expect(Set(MirageHostInputController.recoveryKeyCodes(for: .capsLock)) == Set([0x39]))
    }

    @Test("Domain maps to expected event source state")
    func domainMapsToExpectedEventSourceState() {
        #expect(MirageHostInputController.systemStateSource(for: .session) == .combinedSessionState)
        #expect(MirageHostInputController.systemStateSource(for: .hid) == .hidSystemState)
    }

    @Test("Modifier transition plan reports expected keycode changes")
    func modifierTransitionPlanReportsExpectedChanges() {
        let pressAndReleasePlan = MirageHostInputController.modifierTransitionPlan(
            from: [.command, .control],
            to: [.command, .shift]
        )
        #expect(pressAndReleasePlan.pressed == [0x38])
        #expect(pressAndReleasePlan.released == [0x3B])

        let multiReleasePlan = MirageHostInputController.modifierTransitionPlan(
            from: [.capsLock, .command, .control],
            to: [.shift]
        )
        #expect(multiReleasePlan.pressed == [0x38])
        #expect(multiReleasePlan.released == [0x3B, 0x37, 0x39])
    }
}
#endif
