//
//  HostSharedClipboardTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

@Suite("Host Shared Clipboard")
struct HostSharedClipboardTests {
    @Test("Host registers shared clipboard update handler")
    func registersSharedClipboardHandler() async {
        let service = await MainActor.run { MirageHostService(hostName: "Test Host", deviceID: UUID()) }
        await MainActor.run {
            #expect(service.controlMessageHandlers[.sharedClipboardUpdate] != nil)
        }
    }

    @Test("Host shared clipboard requires toggle ready session and active stream")
    func hostSharedClipboardActivationPolicy() {
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: false,
                sessionState: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionState: .credentialsRequired,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionState: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: true
            )
        )
    }
}
#endif
