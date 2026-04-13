//
//  MirageHostSystemActionLaunchTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/13/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Testing

@Suite("Host System Action Launching")
struct MirageHostSystemActionLaunchTests {
    @Test("Mission Control launches Mission Control.app without arguments")
    func missionControlLaunchArguments() {
        #expect(MirageHostInputController.missionControlLaunchArguments(for: .missionControl) == [])
    }

    @Test("App Expose launches Mission Control.app with the app-windows argument")
    func appExposeLaunchArguments() {
        #expect(MirageHostInputController.missionControlLaunchArguments(for: .appExpose) == ["2"])
    }

    @Test("Space switching continues using shortcut injection")
    func spaceSwitchingDoesNotUseMissionControlLaunch() {
        #expect(MirageHostInputController.missionControlLaunchArguments(for: .spaceLeft) == nil)
        #expect(MirageHostInputController.missionControlLaunchArguments(for: .spaceRight) == nil)
    }
}
#endif
