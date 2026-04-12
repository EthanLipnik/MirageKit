//
//  RemoteClientStreamOptionsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Remote Client Stream Options")
struct HostRemoteClientStreamOptionsTests {
    @MainActor
    @Test("Host-side display mode command updates mirrored state immediately")
    func displayModeCommandUpdatesMirroredState() async {
        let host = MirageHostService()

        #expect(host.remoteClientStreamOptionsDisplayMode == .inStream)

        await host.setRemoteClientStreamOptionsDisplayMode(.hostMenuBar)

        #expect(host.remoteClientStreamOptionsDisplayMode == .hostMenuBar)
    }

    @MainActor
    @Test("Host-side status overlay command updates mirrored state immediately")
    func statusOverlayCommandUpdatesMirroredState() async {
        let host = MirageHostService()

        #expect(host.remoteClientStreamStatusOverlayEnabled == false)

        await host.setRemoteClientStreamStatusOverlayEnabled(true)

        #expect(host.remoteClientStreamStatusOverlayEnabled == true)
    }

    @MainActor
    @Test("Host-side desktop cursor lock mode command updates mirrored state immediately")
    func desktopCursorLockModeCommandUpdatesMirroredState() async {
        let host = MirageHostService()

        #expect(host.remoteClientDesktopCursorLockMode == .off)

        await host.setRemoteClientDesktopCursorLockMode(.allDesktopStreams)

        #expect(host.remoteClientDesktopCursorLockMode == .allDesktopStreams)
    }
}
#endif
