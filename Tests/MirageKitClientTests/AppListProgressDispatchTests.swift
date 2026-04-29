//
//  AppListProgressDispatchTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/29/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CryptoKit
import Foundation
import Testing

@Suite("App List Progress Dispatch")
struct AppListProgressDispatchTests {
    @MainActor
    @Test("Inline icon progress updates available apps in arrival order")
    func inlineIconProgressUpdatesAvailableAppsInArrivalOrder() async throws {
        let service = MirageClientService()
        var progressCallbackCount = 0
        var latestProgressApps: [MirageInstalledApp] = []
        service.onAppListProgress = { apps in
            progressCallbackCount += 1
            latestProgressApps = apps
        }

        let requestID = UUID()
        service.activeAppListRequestID = requestID

        let editorIconData = try Self.validPNGData()
        let editorIconSignature = SHA256.hash(data: editorIconData).map { String(format: "%02x", $0) }.joined()
        let progress = AppListProgressMessage(
            requestID: requestID,
            apps: [
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Editor",
                    name: "Editor",
                    path: "/Applications/Editor.app",
                    iconData: editorIconData,
                    iconSignature: editorIconSignature
                ),
                MirageInstalledApp(
                    bundleIdentifier: "com.example.Terminal",
                    name: "Terminal",
                    path: "/Applications/Utilities/Terminal.app"
                ),
            ]
        )
        await service.handleAppListProgress(try ControlMessage(type: .appListProgress, content: progress))

        #expect(progressCallbackCount == 1)
        #expect(service.availableApps.map(\.bundleIdentifier) == [
            "com.example.Editor",
            "com.example.Terminal",
        ])
        #expect(service.availableApps.first?.iconData == editorIconData)
        #expect(service.availableApps.first?.iconSignature == editorIconSignature)
        #expect(latestProgressApps.first?.iconData == editorIconData)
    }

    @MainActor
    @Test("Progress preserves previous icon when later metadata omits it")
    func progressPreservesPreviousIconWhenMetadataOmitsIt() async throws {
        let service = MirageClientService()
        let requestID = UUID()
        service.activeAppListRequestID = requestID

        let iconData = try Self.validPNGData()
        let iconSignature = SHA256.hash(data: iconData).map { String(format: "%02x", $0) }.joined()
        await service.handleAppListProgress(
            try ControlMessage(
                type: .appListProgress,
                content: AppListProgressMessage(
                    requestID: requestID,
                    apps: [
                        MirageInstalledApp(
                            bundleIdentifier: "com.example.Editor",
                            name: "Editor",
                            path: "/Applications/Editor.app",
                            iconData: iconData,
                            iconSignature: iconSignature
                        ),
                    ]
                )
            )
        )

        await service.handleAppListProgress(
            try ControlMessage(
                type: .appListProgress,
                content: AppListProgressMessage(
                    requestID: requestID,
                    apps: [
                        MirageInstalledApp(
                            bundleIdentifier: "com.example.Editor",
                            name: "Editor",
                            path: "/Applications/Editor.app"
                        ),
                    ]
                )
            )
        )

        #expect(service.availableApps.count == 1)
        #expect(service.availableApps.first?.iconData == iconData)
        #expect(service.availableApps.first?.iconSignature == iconSignature)
    }

    @MainActor
    @Test("Invalid inline icon payload is rejected")
    func invalidInlineIconPayloadIsRejected() async throws {
        let service = MirageClientService()
        let requestID = UUID()
        service.activeAppListRequestID = requestID

        let invalidIconData = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02, 0x03])
        let invalidSignature = SHA256.hash(data: invalidIconData).map { String(format: "%02x", $0) }.joined()
        await service.handleAppListProgress(
            try ControlMessage(
                type: .appListProgress,
                content: AppListProgressMessage(
                    requestID: requestID,
                    apps: [
                        MirageInstalledApp(
                            bundleIdentifier: "com.example.Editor",
                            name: "Editor",
                            path: "/Applications/Editor.app",
                            iconData: invalidIconData,
                            iconSignature: invalidSignature
                        ),
                    ]
                )
            )
        )

        #expect(service.availableApps.first?.iconData == nil)
        #expect(service.availableApps.first?.iconSignature == nil)
    }

    private static func validPNGData() throws -> Data {
        try #require(
            Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+/p9sAAAAASUVORK5CYII=")
        )
    }
}
