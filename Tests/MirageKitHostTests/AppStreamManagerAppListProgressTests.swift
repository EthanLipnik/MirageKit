//
//  AppStreamManagerAppListProgressTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/28/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("App stream manager app-list progress")
struct AppStreamManagerAppListProgressTests {
    @Test("Cached app replay emits each app through progress callback")
    func cachedAppReplayEmitsEachAppThroughProgressCallback() async {
        let manager = AppStreamManager()
        let recorder = AppReplayRecorder()
        let apps = [
            MirageInstalledApp(
                bundleIdentifier: "com.example.Editor",
                name: "Editor",
                path: "/Applications/Editor.app"
            ),
            MirageInstalledApp(
                bundleIdentifier: "com.example.Terminal",
                name: "Terminal",
                path: "/Applications/Utilities/Terminal.app"
            ),
        ]

        await manager.replayInstalledApps(apps) { app in
            await recorder.record(app)
        }

        let bundleIdentifiers = await recorder.bundleIdentifiers
        #expect(bundleIdentifiers == [
            "com.example.Editor",
            "com.example.Terminal",
        ])
    }

    @MainActor
    @Test("App-list progress order preserves priorities then sorts remaining apps")
    func appListProgressOrderPreservesPrioritiesThenSortsRemainingApps() {
        let service = MirageHostService(hostName: "Test Host")
        let apps = [
            MirageInstalledApp(
                bundleIdentifier: "com.example.Zed",
                name: "Zed",
                path: "/Applications/Zed.app"
            ),
            MirageInstalledApp(
                bundleIdentifier: "com.example.Editor",
                name: "Editor",
                path: "/Applications/Editor.app"
            ),
            MirageInstalledApp(
                bundleIdentifier: "com.example.Terminal",
                name: "Terminal",
                path: "/Applications/Utilities/Terminal.app"
            ),
        ]

        let orderedApps = service.orderedAppsForAppListProgress(
            apps,
            priorityBundleIdentifiers: [
                "com.example.terminal",
                "com.example.missing",
            ]
        )

        #expect(orderedApps.map(\.bundleIdentifier) == [
            "com.example.Terminal",
            "com.example.Editor",
            "com.example.Zed",
        ])
    }

    @MainActor
    @Test("App-list progress order sends unknown icons before known icons")
    func appListProgressOrderSendsUnknownIconsBeforeKnownIcons() {
        let service = MirageHostService(hostName: "Test Host")
        let apps = [
            MirageInstalledApp(
                bundleIdentifier: "com.example.Zed",
                name: "Zed",
                path: "/Applications/Zed.app"
            ),
            MirageInstalledApp(
                bundleIdentifier: "com.example.Editor",
                name: "Editor",
                path: "/Applications/Editor.app"
            ),
            MirageInstalledApp(
                bundleIdentifier: "com.example.Terminal",
                name: "Terminal",
                path: "/Applications/Utilities/Terminal.app"
            ),
        ]

        let orderedApps = service.orderedAppsForAppListProgress(
            apps,
            priorityBundleIdentifiers: ["com.example.terminal"],
            knownIconBundleIdentifiers: [
                "com.example.editor",
                "com.example.terminal",
            ]
        )

        #expect(orderedApps.map(\.bundleIdentifier) == [
            "com.example.Terminal",
            "com.example.Zed",
            "com.example.Editor",
        ])
    }
}

private actor AppReplayRecorder {
    private var apps: [MirageInstalledApp] = []

    var bundleIdentifiers: [String] {
        apps.map(\.bundleIdentifier)
    }

    func record(_ app: MirageInstalledApp) {
        apps.append(app)
    }
}
#endif
