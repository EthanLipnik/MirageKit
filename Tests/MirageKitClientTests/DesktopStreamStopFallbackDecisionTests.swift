//
//  DesktopStreamStopFallbackDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Foundation
import Testing

@Suite("Desktop Stream Stop Fallback Decision")
struct DesktopStreamStopFallbackDecisionTests {
    @Test("Force local desktop stop only while the stream still has local state")
    func forceLocalDesktopStopOnlyWhileStateRemains() {
        let desktopSessionID = UUID()
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: 7,
                activeDesktopSessionID: desktopSessionID,
                hasController: false,
                isRegistered: false
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: nil,
                activeDesktopSessionID: nil,
                hasController: true,
                isRegistered: false
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: nil,
                activeDesktopSessionID: nil,
                hasController: false,
                isRegistered: true
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                requestedDesktopSessionID: desktopSessionID,
                activeDesktopStreamID: nil,
                activeDesktopSessionID: nil,
                hasController: false,
                isRegistered: false
            ) == false
        )
    }

    @Test("Force local desktop stop is skipped once a new desktop session is active")
    func forceLocalDesktopStopSkipsSupersededDesktopSession() {
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                requestedDesktopSessionID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
                activeDesktopStreamID: 7,
                activeDesktopSessionID: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
                hasController: true,
                isRegistered: true
            ) == false
        )
    }
}
