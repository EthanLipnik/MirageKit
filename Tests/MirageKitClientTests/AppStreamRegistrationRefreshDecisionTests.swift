//
//  AppStreamRegistrationRefreshDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  App stream registration refresh decision coverage.
//

@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("App Stream Registration Refresh Decision")
struct AppStreamRegistrationRefreshDecisionTests {
    @Test("New stream refreshes registration")
    func newStreamRefreshesRegistration() {
        let decision = appStreamRegistrationRefreshDecision(
            hasController: false,
            shouldResetController: true,
            wasRegistered: false
        )

        #expect(decision == .refreshRegistration)
    }

    @Test("Controller reset refreshes registration")
    func controllerResetRefreshesRegistration() {
        let decision = appStreamRegistrationRefreshDecision(
            hasController: true,
            shouldResetController: true,
            wasRegistered: true
        )

        #expect(decision == .refreshRegistration)
    }

    @Test("Missing registration refreshes existing stream")
    func missingRegistrationRefreshesExistingStream() {
        let decision = appStreamRegistrationRefreshDecision(
            hasController: true,
            shouldResetController: false,
            wasRegistered: false
        )

        #expect(decision == .refreshRegistration)
    }

    @Test("Stable stream reuses registration")
    func stableStreamReusesRegistration() {
        let decision = appStreamRegistrationRefreshDecision(
            hasController: true,
            shouldResetController: false,
            wasRegistered: true
        )

        #expect(decision == .reuseRegistration)
    }
}
#endif
