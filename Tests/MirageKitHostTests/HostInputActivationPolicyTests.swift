//
//  HostInputActivationPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  Input-driven window activation policy decisions.
//

@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Input Activation Policy")
struct HostInputActivationPolicyTests {
    @Test("Window focus activation is throttled")
    func windowFocusActivationIsThrottled() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: 20.0,
            now: 20.1
        )

        #expect(action == .none)
    }

    @Test("Window focus without recent activation performs full raise")
    func windowFocusPerformsFullRaiseWhenAllowed() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: nil,
            now: 30.0
        )

        #expect(action == .fullWindowRaise)
    }

    @Test("Throttled activation resumes after interval")
    func throttledActivationResumesAfterInterval() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: 40.0,
            now: 40.30
        )

        #expect(action == .fullWindowRaise)
    }
}
#endif
