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
