//
//  DesktopStopSessionScopeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/14/26.
//

@testable import MirageKitHost
import Foundation
import Testing

#if os(macOS)
@Suite("Desktop Stop Session Scope")
struct DesktopStopSessionScopeTests {
    @Test("Desktop stop requests are ignored when the desktop session has been replaced")
    func desktopStopRequestsAreIgnoredWhenDesktopSessionHasBeenReplaced() {
        #expect(
            shouldAcceptStopDesktopStreamRequest(
                requestedStreamID: 21,
                requestedDesktopSessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                activeDesktopStreamID: 21,
                activeDesktopSessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
            ) == false
        )
    }

    @Test("Desktop stop requests are accepted for the active desktop session")
    func desktopStopRequestsAreAcceptedForTheActiveDesktopSession() {
        let desktopSessionID = UUID()

        #expect(
            shouldAcceptStopDesktopStreamRequest(
                requestedStreamID: 21,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: 21,
                activeDesktopSessionID: desktopSessionID
            )
        )
    }
}
#endif
