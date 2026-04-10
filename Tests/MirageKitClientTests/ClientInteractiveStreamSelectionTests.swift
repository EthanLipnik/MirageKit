//
//  ClientInteractiveStreamSelectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/9/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Client Interactive Stream Selection")
struct ClientInteractiveStreamSelectionTests {
    @MainActor
    @Test("Desktop-only sessions are included in active interactive stream IDs")
    func desktopOnlySessionsAreIncluded() {
        let service = MirageClientService(deviceName: "Test Device")
        service.desktopStreamID = 42

        #expect(service.activeInteractiveStreamIDs == [42])
    }

    @MainActor
    @Test("Desktop stream IDs are deduplicated when the same stream is present in app sessions")
    func duplicateDesktopStreamIDsAreDeduplicated() {
        let service = MirageClientService(deviceName: "Test Device")
        service.desktopStreamID = 42
        service.activeStreams = [
            ClientStreamSession(id: 42, window: makeWindow(id: 1)),
            ClientStreamSession(id: 73, window: makeWindow(id: 2)),
        ]

        #expect(service.activeInteractiveStreamIDs == [42, 73])
    }
}

private func makeWindow(id: WindowID) -> MirageWindow {
    MirageWindow(
        id: id,
        title: "Window \(id)",
        application: nil,
        frame: CGRect(x: 0, y: 0, width: 100, height: 100),
        isOnScreen: true,
        windowLayer: 0
    )
}
