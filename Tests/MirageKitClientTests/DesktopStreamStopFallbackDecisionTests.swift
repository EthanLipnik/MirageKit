//
//  DesktopStreamStopFallbackDecisionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Desktop Stream Stop Fallback Decision")
struct DesktopStreamStopFallbackDecisionTests {
    @Test("Force local desktop stop only while the stream still has local state")
    func forceLocalDesktopStopOnlyWhileStateRemains() {
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                activeDesktopStreamID: 7,
                hasController: false,
                isRegistered: false
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                activeDesktopStreamID: nil,
                hasController: true,
                isRegistered: false
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                activeDesktopStreamID: nil,
                hasController: false,
                isRegistered: true
            )
        )
        #expect(
            MirageClientService.shouldForceLocalDesktopStopAfterTimeout(
                requestedStreamID: 7,
                activeDesktopStreamID: nil,
                hasController: false,
                isRegistered: false
            ) == false
        )
    }
}
