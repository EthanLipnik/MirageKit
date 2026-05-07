//
//  AppAtlasLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/4/26.
//

#if os(macOS)
@testable import MirageKit
@testable import MirageKitHost
import CoreGraphics
import Foundation
import Testing

@Suite("App Atlas Lifecycle")
struct AppAtlasLifecycleTests {
    @Test("Logical session lookup is scoped to coordinator streams and client")
    @MainActor
    func logicalSessionLookupIsScopedToCoordinatorStreamsAndClient() {
        let host = MirageHostService()
        let client = makeClient(id: UUID(), name: "iPad")
        let otherClient = makeClient(id: UUID(), name: "Mac")

        let first = makeSession(streamID: 11, windowID: 101, client: client)
        let second = makeSession(streamID: 12, windowID: 102, client: client)
        let unrelatedSameClient = makeSession(streamID: 13, windowID: 103, client: client)
        let unrelatedOtherClient = makeSession(streamID: 14, windowID: 104, client: otherClient)

        host.registerActiveStreamSession(first)
        host.registerActiveStreamSession(second)
        host.registerActiveStreamSession(unrelatedSameClient)
        host.registerActiveStreamSession(unrelatedOtherClient)

        let sessions = host.appAtlasLogicalSessions(clientID: client.id, streamIDs: [12, 14, 11])

        #expect(sessions.map(\.id) == [11, 12])
    }

    @Test("Auxiliary parent association prefers overlap then nearest center")
    func auxiliaryParentAssociationPrefersOverlapThenNearestCenter() {
        let streamID = MirageHostService.bestAuxiliaryParentStream(
            auxiliaryFrame: CGRect(x: 460, y: 120, width: 120, height: 80),
            visibleParents: [
                (streamID: 21, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
                (streamID: 22, frame: CGRect(x: 500, y: 0, width: 400, height: 400)),
            ]
        )
        let nearestStreamID = MirageHostService.bestAuxiliaryParentStream(
            auxiliaryFrame: CGRect(x: 420, y: 120, width: 40, height: 80),
            visibleParents: [
                (streamID: 31, frame: CGRect(x: 0, y: 0, width: 400, height: 400)),
                (streamID: 32, frame: CGRect(x: 500, y: 0, width: 400, height: 400)),
            ]
        )

        #expect(streamID == 22)
        #expect(nearestStreamID == 31)
    }

    private func makeClient(id: UUID, name: String) -> MirageConnectedClient {
        MirageConnectedClient(
            id: id,
            name: name,
            deviceType: .iPad,
            connectedAt: Date()
        )
    }

    private func makeSession(
        streamID: StreamID,
        windowID: WindowID,
        client: MirageConnectedClient
    ) -> MirageStreamSession {
        MirageStreamSession(
            id: streamID,
            window: MirageWindow(
                id: windowID,
                title: "Window \(windowID)",
                application: MirageApplication(
                    id: 1000 + pid_t(windowID),
                    bundleIdentifier: "com.example.app",
                    name: "Example"
                ),
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isOnScreen: true,
                windowLayer: 0
            ),
            client: client
        )
    }
}
#endif
