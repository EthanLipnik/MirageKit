//
//  MultiWindowAppStreamingLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

@testable import MirageKitHost
import CoreGraphics
import Foundation
import MirageKit
import Testing

#if os(macOS)
extension MultiWindowAppStreamingStabilizationTests {
    @MainActor
    @Test("Active stream maps remain consistent across register/update/remove")
    func activeStreamMapsRemainConsistent() async {
        let host = MirageHostService(hostName: "MapConsistencyHost")
        let client = MirageConnectedClient(
            id: UUID(),
            name: "Client",
            deviceType: .mac,
            connectedAt: Date()
        )

        let initialWindow = makeWindow(id: 7001, title: "Initial", origin: CGPoint(x: 20, y: 20))
        host.registerActiveStreamSession(
            MirageStreamSession(id: 55, window: initialWindow, client: client)
        )

        #expect(host.activeSessionByStreamID[55]?.window.id == 7001)
        #expect(host.activeStreamIDByWindowID[7001] == 55)
        #expect(host.activeWindowIDByStreamID[55] == 7001)

        let remappedWindow = makeWindow(id: 7002, title: "Remapped", origin: CGPoint(x: 30, y: 30))
        host.registerActiveStreamSession(
            MirageStreamSession(id: 55, window: remappedWindow, client: client)
        )

        #expect(host.activeSessionByStreamID[55]?.window.id == 7002)
        #expect(host.activeStreamIDByWindowID[7001] == nil)
        #expect(host.activeStreamIDByWindowID[7002] == 55)
        #expect(host.activeWindowIDByStreamID[55] == 7002)

        host.removeActiveStreamSession(streamID: 55)

        #expect(host.activeSessionByStreamID[55] == nil)
        #expect(host.activeStreamIDByWindowID[7002] == nil)
        #expect(host.activeWindowIDByStreamID[55] == nil)
    }

    @MainActor
    @Test("New primary window stays hidden when an existing streamed window is healthy")
    func newPrimaryWindowStaysHiddenWhenExistingStreamedWindowIsHealthy() async {
        let host = MirageHostService(hostName: "LifecycleHost")
        let clientID = UUID()
        let bundleID = "com.example.app"
        let streamedWindowID = WindowID(9131)
        let newWindowID = WindowID(9132)

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleID,
            appName: "Example App",
            appPath: "/Applications/Example.app",
            clientID: clientID,
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1280, height: 720),
            requestedClientScaleFactor: nil,
            maxVisibleSlots: 1,
            bitrateBudgetBps: nil
        )
        await host.appStreamManager.markSessionStreaming(bundleID)
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleID,
            windowID: streamedWindowID,
            streamID: 77,
            title: "Current Project",
            width: 1280,
            height: 720,
            isResizable: true,
            slotIndex: 0,
            mediaStreamID: 77
        )

        let newCandidate = makeCandidate(
            windowID: newWindowID,
            title: "Second Project",
            origin: CGPoint(x: 120, y: 120)
        )
        await host.handleNewWindowFromStreamedApp(bundleID: bundleID, candidate: newCandidate)

        let session = await host.appStreamManager.session(bundleIdentifier: bundleID)
        let visibleWindowIDs = session.map { Array($0.windowStreams.keys).sorted(by: <) } ?? []
        #expect(visibleWindowIDs == [streamedWindowID])
        #expect(session?.hiddenWindows[newWindowID] != nil)
    }

    @MainActor
    @Test("Existing app session slot cap can rise after entitlement restore")
    func existingAppSessionSlotCapCanRiseAfterEntitlementRestore() async {
        let host = MirageHostService(hostName: "LifecycleHost")
        let clientID = UUID()
        let bundleID = "com.example.app"

        _ = await host.appStreamManager.startAppSession(
            bundleIdentifier: bundleID,
            appName: "Example App",
            appPath: "/Applications/Example.app",
            clientID: clientID,
            clientName: "Client",
            requestedDisplayResolution: CGSize(width: 1280, height: 720),
            requestedClientScaleFactor: nil,
            maxVisibleSlots: 1,
            bitrateBudgetBps: nil
        )
        _ = await host.appStreamManager.addWindowToSession(
            bundleIdentifier: bundleID,
            windowID: 7001,
            streamID: 77,
            title: "Current Project",
            width: 1280,
            height: 720,
            isResizable: true,
            slotIndex: 0,
            mediaStreamID: 77
        )

        #expect(!(await host.appStreamManager.hasVisibleSlotCapacity(bundleIdentifier: bundleID)))

        await host.appStreamManager.raiseMaxVisibleSlots(bundleIdentifier: bundleID, to: 8)

        #expect(await host.appStreamManager.hasVisibleSlotCapacity(bundleIdentifier: bundleID))
        #expect(await host.appStreamManager.session(bundleIdentifier: bundleID)?.maxVisibleSlots == 8)
        #expect(await host.appStreamManager.inventoryMessage(bundleIdentifier: bundleID)?.maxVisibleSlots == 8)
    }
}
#endif
