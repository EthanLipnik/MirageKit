//
//  AppStreamStartResetDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App stream start reset decision coverage.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("App Stream Start Reset Decision")
struct AppStreamStartResetDecisionTests {
    @Test("Initial app stream start resets controller")
    func initialAppStartResetsController() {
        let decision = appStreamStartResetDecision(
            streamID: 11,
            isExistingStream: false,
            hasController: false,
            requestStartPending: false,
            previousDimensionToken: nil,
            receivedDimensionToken: 0
        )

        #expect(decision == .resetController)
    }

    @Test("Request-start pending resets controller")
    func requestStartPendingResetsController() {
        let decision = appStreamStartResetDecision(
            streamID: 11,
            isExistingStream: true,
            hasController: true,
            requestStartPending: true,
            previousDimensionToken: 2,
            receivedDimensionToken: 2
        )

        #expect(decision == .resetController)
    }

    @Test("Same stream and token reuses controller")
    func sameStreamAndTokenReusesController() {
        let decision = appStreamStartResetDecision(
            streamID: 11,
            isExistingStream: true,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 4,
            receivedDimensionToken: 4
        )

        #expect(decision == .reuseController)
    }

    @Test("Token mismatch resets controller")
    func tokenMismatchResetsController() {
        let decision = appStreamStartResetDecision(
            streamID: 11,
            isExistingStream: true,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 4,
            receivedDimensionToken: 5
        )

        #expect(decision == .resetController)
    }

    @Test("Missing controller resets existing stream")
    func missingControllerResetsExistingStream() {
        let decision = appStreamStartResetDecision(
            streamID: 11,
            isExistingStream: true,
            hasController: false,
            requestStartPending: false,
            previousDimensionToken: 4,
            receivedDimensionToken: 4
        )

        #expect(decision == .resetController)
    }
}
#endif
