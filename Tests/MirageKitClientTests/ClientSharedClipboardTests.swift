//
//  ClientSharedClipboardTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Client Shared Clipboard")
struct ClientSharedClipboardTests {
    @Test("Client shared clipboard requires connected host-enabled active streaming")
    func clientSharedClipboardActivationPolicy() {
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .disconnected,
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: false,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: false,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageClientService.shouldEnableSharedClipboard(
                connectionState: .connected(host: "Host"),
                hostSharedClipboardEnabled: true,
                clientClipboardSharingEnabled: true,
                hasAppStreams: false,
                hasDesktopStream: true
            )
        )
    }

    @Test("Status handler updates runtime state")
    func sharedClipboardStatusHandlerUpdatesRuntimeState() async throws {
        let enabledMessage = try ControlMessage(
            type: .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: true)
        )

        let service = await MainActor.run {
            let service = MirageClientService(deviceName: "Shared Clipboard Client")
            service.connectionState = .connected(host: "Host")
            return service
        }
        await MainActor.run {
            service.handleSharedClipboardStatus(enabledMessage)
            #expect(service.sharedClipboardEnabled)
        }
    }
}
