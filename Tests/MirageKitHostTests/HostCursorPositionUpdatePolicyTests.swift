//
//  HostCursorPositionUpdatePolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/1/26.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@MainActor
@Suite("Host Cursor Position Update Policy")
struct HostCursorPositionUpdatePolicyTests {
    @Test("Secondary desktop streams always publish cursor positions")
    func secondaryDesktopStreamPublishesCursorPositions() {
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 42,
            desktopStreamID: 42,
            desktopStreamMode: .secondary,
            desktopCursorPresentation: .clientCursor
        )

        #expect(shouldSend)
    }

    @Test("Host cursor desktop streams publish cursor positions even when mirrored")
    func hostCursorMirroredDesktopPublishesCursorPositions() {
        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: false
        )
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 7,
            desktopStreamID: 7,
            desktopStreamMode: .mirrored,
            desktopCursorPresentation: presentation
        )

        #expect(shouldSend)
    }

    @Test("Mirrored desktop with synthetic cursor skips cursor positions")
    func mirroredDesktopWithSyntheticCursorSkipsCursorPositions() {
        let shouldSend = MirageHostService.shouldSendCursorPositionUpdate(
            streamID: 7,
            desktopStreamID: 7,
            desktopStreamMode: .mirrored,
            desktopCursorPresentation: .clientCursor
        )

        #expect(shouldSend == false)
    }
}
#endif
