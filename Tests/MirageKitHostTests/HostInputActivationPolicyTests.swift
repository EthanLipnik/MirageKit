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
    @Test("Same-window focus activation is throttled")
    func sameWindowFocusActivationIsThrottled() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: 20.0,
            lastActivatedWindowID: 11,
            targetWindowID: 11,
            now: 20.1
        )

        #expect(action == .none)
    }

    @Test("Cross-window focus activation bypasses throttle")
    func crossWindowFocusActivationBypassesThrottle() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: 50.0,
            lastActivatedWindowID: 20,
            targetWindowID: 21,
            now: 50.01
        )

        #expect(action == .fullWindowRaise)
    }

    @Test("Same-window throttled activation resumes after interval")
    func sameWindowThrottledActivationResumesAfterInterval() {
        let action = HostInputActivationPolicy.action(
            for: .windowFocus,
            lastActivationTime: 40.0,
            lastActivatedWindowID: 33,
            targetWindowID: 33,
            now: 40.30
        )

        #expect(action == .fullWindowRaise)
    }
}
#endif
