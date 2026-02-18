//
//  DesktopStreamStartResetDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/18/26.
//
//  Desktop stream start reset decision coverage.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

#if os(macOS)
@Suite("Desktop Stream Start Reset Decision")
struct DesktopStreamStartResetDecisionTests {
    @Test("Initial desktop start resets controller")
    func initialDesktopStartResetsController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: nil,
            hasController: false,
            requestStartPending: false,
            previousDimensionToken: nil,
            receivedDimensionToken: 0
        )

        #expect(decision == .resetController)
    }

    @Test("Same stream and token reuses controller")
    func sameStreamSameTokenReusesController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 12
        )

        #expect(decision == .reuseController)
    }

    @Test("Same stream with changed token resets controller")
    func sameStreamChangedTokenResetsController() {
        let decision = desktopStreamStartResetDecision(
            streamID: 7,
            previousStreamID: 7,
            hasController: true,
            requestStartPending: false,
            previousDimensionToken: 12,
            receivedDimensionToken: 13
        )

        #expect(decision == .resetController)
    }

    @MainActor
    @Test("Desktop stop clears tracked token for stream")
    func desktopStopClearsTrackedToken() throws {
        let service = MirageClientService()
        service.desktopDimensionTokenByStream[9] = 22
        service.desktopDimensionTokenByStream[11] = 5

        let stopped = DesktopStreamStoppedMessage(streamID: 9, reason: .clientRequested)
        let envelope = try ControlMessage(type: .desktopStreamStopped, content: stopped)
        service.handleDesktopStreamStopped(envelope)

        #expect(service.desktopDimensionTokenByStream[9] == nil)
        #expect(service.desktopDimensionTokenByStream[11] == 5)
    }
}
#endif
