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
        let metadataList = AppListMessage(
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
        let metadataEnvelope = try ControlMessage(type: .appList, content: metadataList)
        service.handleAppList(metadataEnvelope)

        #expect(callbackCount == 1)
        #expect(latestApps.count == 1)
        #expect(latestApps.first?.iconData == nil)

        let iconData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
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
}
