//
//  RemoteClientStreamOptionsTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Remote Client Stream Options")
struct RemoteClientStreamOptionsTests {
    @MainActor
    @Test("Host command updates client callbacks for stream-option and stop actions")
    func remoteClientCommandUpdatesCallbacks() throws {
        let service = MirageClientService()
        var receivedDisplayMode: MirageStreamOptionsDisplayMode?
        var receivedStatusOverlayEnabled: Bool?
        var receivedCursorPresentation: MirageDesktopCursorPresentation?
        var receivedStoppedAppBundleIdentifier: String?
        var receivedStopDesktopStream = false

        service.onRemoteClientStreamOptionsDisplayModeCommand = { receivedDisplayMode = $0 }
        service.onRemoteClientStreamStatusOverlayCommand = { receivedStatusOverlayEnabled = $0 }
        service.onRemoteClientDesktopCursorPresentationCommand = { receivedCursorPresentation = $0 }
        service.onRemoteClientStopAppStreamCommand = { receivedStoppedAppBundleIdentifier = $0 }
        service.onRemoteClientStopDesktopStreamCommand = { receivedStopDesktopStream = true }

        let presentation = MirageDesktopCursorPresentation(
            source: .host,
            lockClientCursorWhenUsingMirageCursor: false,
            lockClientCursorWhenUsingHostCursor: false
        )
        let command = RemoteClientStreamOptionsCommandMessage(
            displayMode: .hostMenuBar,
            statusOverlayEnabled: true,
            desktopCursorPresentation: presentation,
            stopAppBundleIdentifier: "com.example.app",
            stopDesktopStream: true
        )
        let envelope = try ControlMessage(type: .remoteClientStreamOptionsCommand, content: command)

        service.handleRemoteClientStreamOptionsCommand(envelope)

        #expect(receivedDisplayMode == .hostMenuBar)
        #expect(receivedStatusOverlayEnabled == true)
        #expect(receivedCursorPresentation == presentation)
        #expect(receivedStoppedAppBundleIdentifier == "com.example.app")
        #expect(receivedStopDesktopStream == true)
    }
}
