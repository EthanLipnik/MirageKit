//
//  AppWindowCloseBlockedAlertPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Host policy tests for client-window-close host close attempts and
//  close-blocked alert presentation stream selection.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Testing

@Suite("App Window Close-Blocked Alert Policy")
struct AppWindowCloseBlockedAlertPolicyTests {
    @Test("Host close decision matrix respects origin setting and app-stream scope")
    func hostCloseDecisionMatrix() {
        #expect(
            MirageHostService.clientWindowCloseHostWindowCloseDecision(
                origin: nil,
                closeHostWindowOnClientWindowClose: true,
                hasAppStreamSession: true
            ) == .skipOriginNotClientWindowClosed
        )
        #expect(
            MirageHostService.clientWindowCloseHostWindowCloseDecision(
                origin: .clientWindowClosed,
                closeHostWindowOnClientWindowClose: false,
                hasAppStreamSession: true
            ) == .skipSettingDisabled
        )
        #expect(
            MirageHostService.clientWindowCloseHostWindowCloseDecision(
                origin: .clientWindowClosed,
                closeHostWindowOnClientWindowClose: true,
                hasAppStreamSession: false
            ) == .skipNoAppStreamSession
        )
        #expect(
            MirageHostService.clientWindowCloseHostWindowCloseDecision(
                origin: .clientWindowClosed,
                closeHostWindowOnClientWindowClose: true,
                hasAppStreamSession: true
            ) == .attemptHostWindowClose
        )
    }

    @Test("Presenting stream selection excludes closing stream and non-window streams")
    func presentingStreamSelectionExcludesClosingStreamAndNonWindowStreams() {
        let targetClientID = UUID()
        let otherClientID = UUID()

        let streams = [
            makeStream(streamID: 40, windowID: 0, clientID: targetClientID),
            makeStream(streamID: 22, windowID: 220, clientID: targetClientID),
            makeStream(streamID: 70, windowID: 700, clientID: targetClientID),
            makeStream(streamID: 10, windowID: 100, clientID: otherClientID),
        ]

        let selected = MirageHostService.appWindowCloseAlertPresentingStreamID(
            activeStreams: streams,
            clientID: targetClientID,
            excludingStreamID: 70
        )

        #expect(selected == 22)
    }

    @Test("Presenting stream selection returns nil when no remaining stream exists")
    func presentingStreamSelectionReturnsNilWhenNoRemainingStreamExists() {
        let targetClientID = UUID()
        let streams = [
            makeStream(streamID: 55, windowID: 555, clientID: targetClientID),
            makeStream(streamID: 80, windowID: 800, clientID: UUID()),
        ]

        let selected = MirageHostService.appWindowCloseAlertPresentingStreamID(
            activeStreams: streams,
            clientID: targetClientID,
            excludingStreamID: 55
        )

        #expect(selected == nil)
    }

    private func makeStream(
        streamID: StreamID,
        windowID: WindowID,
        clientID: UUID
    ) -> MirageStreamSession {
        let client = MirageConnectedClient(
            id: clientID,
            name: "Client-\(clientID.uuidString.prefix(4))",
            deviceType: .mac,
            connectedAt: Date()
        )
        let window = MirageWindow(
            id: windowID,
            title: "Window-\(windowID)",
            application: MirageApplication(
                id: 100,
                bundleIdentifier: "com.example.app",
                name: "Example"
            ),
            frame: CGRect(x: 0, y: 0, width: 1280, height: 720),
            isOnScreen: true,
            windowLayer: 0
        )
        return MirageStreamSession(id: streamID, window: window, client: client)
    }
}
#endif
