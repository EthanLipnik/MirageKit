//
//  AppIconUpdateDispatchTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/4/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CryptoKit
import Foundation
import Testing

@Suite("App Icon Update Dispatch")
struct AppIconUpdateDispatchTests {
    @MainActor
    @Test("App list callback is consolidated across icon packet updates")
    func appListCallbackConsolidatesIconPackets() throws {
        let service = MirageClientService()
        var callbackCount = 0
        var latestApps: [MirageInstalledApp] = []
        var progressCallbackCount = 0
        var latestProgressApps: [MirageInstalledApp] = []
        service.onAppListReceived = { apps in
            callbackCount += 1
            latestApps = apps
        }
        service.onAppIconStreamProgress = { apps in
            progressCallbackCount += 1
            latestProgressApps = apps
        }

        let requestID = UUID()
        service.activeAppListRequestID = requestID
        service.appListMetadataBundleIdentifiersByRequestID[requestID] = []
        service.appIconStreamStateByRequestID[requestID] = MirageClientService.AppIconStreamState()

        let metadataProgress = AppListProgressMessage(
            requestID: requestID,
            apps: [
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Editor",
                    name: "Editor",
                    path: "/Applications/Editor.app",
                    iconData: nil
                ),
            ]
        )
        let metadataEnvelope = try ControlMessage(type: .appListProgress, content: metadataProgress)
        service.handleAppListProgress(metadataEnvelope)
        let metadataComplete = AppListCompleteMessage(requestID: requestID, totalAppCount: 1)
        let metadataCompleteEnvelope = try ControlMessage(type: .appListComplete, content: metadataComplete)
        service.handleAppListComplete(metadataCompleteEnvelope)

        #expect(callbackCount == 1)
        #expect(latestApps.count == 1)
        #expect(latestApps.first?.iconData == nil)

        let iconData = Self.validPNGData
        let iconSignature = SHA256.hash(data: iconData).map { String(format: "%02x", $0) }.joined()
        let iconUpdate = AppIconUpdateMessage(
            requestID: requestID,
            bundleIdentifier: "com.example.Editor",
            iconData: iconData,
            iconSignature: iconSignature
        )
        let iconEnvelope = try ControlMessage(type: .appIconUpdate, content: iconUpdate)
        service.handleAppIconUpdate(iconEnvelope)

        // Icon packet updates should not emit full app-list callbacks.
        #expect(callbackCount == 1)
        #expect(progressCallbackCount == 1)
        #expect(service.availableApps.first?.iconData == iconData)
        #expect(service.availableApps.first?.iconSignature == iconSignature)
        #expect(latestProgressApps.first?.iconData == iconData)
        #expect(latestProgressApps.first?.iconSignature == iconSignature)

        let completion = AppIconStreamCompleteMessage(
            requestID: requestID,
            sentIconCount: 1,
            skippedBundleIdentifiers: []
        )
        let completionEnvelope = try ControlMessage(type: .appIconStreamComplete, content: completion)
        service.handleAppIconStreamComplete(completionEnvelope)

        #expect(callbackCount == 2)
        #expect(progressCallbackCount == 1)
        #expect(latestApps.first?.iconData == iconData)
        #expect(latestApps.first?.iconSignature == iconSignature)
    }

    @MainActor
    @Test("App list progress grows available apps before the final snapshot")
    func appListProgressGrowsAvailableAppsBeforeFinalSnapshot() throws {
        let service = MirageClientService()
        var progressCallbackCount = 0
        var latestProgressApps: [MirageInstalledApp] = []
        service.onAppListProgress = { apps in
            progressCallbackCount += 1
            latestProgressApps = apps
        }

        let requestID = UUID()
        service.activeAppListRequestID = requestID
        service.appListMetadataBundleIdentifiersByRequestID[requestID] = []

        let progress = AppListProgressMessage(
            requestID: requestID,
            apps: [
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Editor",
                    name: "Editor",
                    path: "/Applications/Editor.app",
                    iconData: nil
                ),
            ]
        )
        let progressEnvelope = try ControlMessage(type: .appListProgress, content: progress)
        service.handleAppListProgress(progressEnvelope)

        #expect(progressCallbackCount == 1)
        #expect(service.availableApps.count == 1)
        #expect(latestProgressApps.first?.bundleIdentifier == "com.example.Editor")

        let secondProgress = AppListProgressMessage(
            requestID: requestID,
            apps: [
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Terminal",
                    name: "Terminal",
                    path: "/Applications/Utilities/Terminal.app",
                    iconData: nil
                ),
            ]
        )
        let secondEnvelope = try ControlMessage(type: .appListProgress, content: secondProgress)
        service.handleAppListProgress(secondEnvelope)

        #expect(progressCallbackCount == 2)
        #expect(service.availableApps.map(\.bundleIdentifier) == [
            "com.example.Editor",
            "com.example.Terminal",
        ])
    }

    @MainActor
    @Test("Invalid icon payloads are rejected even with matching signatures")
    func invalidIconPayloadsAreRejected() throws {
        let service = MirageClientService()
        let requestID = UUID()
        service.activeAppListRequestID = requestID
        service.appListMetadataBundleIdentifiersByRequestID[requestID] = []
        service.appIconStreamStateByRequestID[requestID] = MirageClientService.AppIconStreamState()

        let progress = AppListProgressMessage(
            requestID: requestID,
            apps: [
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Editor",
                    name: "Editor",
                    path: "/Applications/Editor.app"
                ),
            ]
        )
        service.handleAppListProgress(try ControlMessage(type: .appListProgress, content: progress))
        let completion = AppListCompleteMessage(requestID: requestID, totalAppCount: 1)
        service.handleAppListComplete(try ControlMessage(type: .appListComplete, content: completion))

        let invalidIconData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
        let invalidSignature = SHA256.hash(data: invalidIconData).map { String(format: "%02x", $0) }.joined()
        let update = AppIconUpdateMessage(
            requestID: requestID,
            bundleIdentifier: "com.example.Editor",
            iconData: invalidIconData,
            iconSignature: invalidSignature
        )

        service.handleAppIconUpdate(try ControlMessage(type: .appIconUpdate, content: update))

        #expect(service.availableApps.first?.iconData == nil)
        #expect(service.pendingForceIconResetForNextAppListRequest)
    }

    private static let validPNGData = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII="
    )!
}
