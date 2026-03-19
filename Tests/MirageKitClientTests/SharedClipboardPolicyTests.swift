//
//  SharedClipboardPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

@testable import MirageKitClient
import Foundation
import MirageKit
import Testing

@Suite("Client Shared Clipboard Policy")
struct SharedClipboardPolicyTests {
    @Test("Client registers shared clipboard handlers")
    func registersSharedClipboardHandlers() async {
        let service = await MainActor.run { MirageClientService(deviceName: "Test Device") }
        await MainActor.run {
            #expect(service.controlMessageHandlers[.sharedClipboardStatus] != nil)
            #expect(service.controlMessageHandlers[.sharedClipboardUpdate] != nil)
        }
    }

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

    @Test("Status handler updates runtime state only when feature was negotiated")
    func sharedClipboardStatusHandlerNegotiationGate() async throws {
        let enabledMessage = try ControlMessage(
            type: .sharedClipboardStatus,
            content: SharedClipboardStatusMessage(enabled: true)
        )

        let negotiatedService = await MainActor.run {
            let service = MirageClientService(deviceName: "Negotiated Client")
            service.negotiatedFeatures = [.sharedClipboardV1]
            service.connectionState = .connected(host: "Host")
            return service
        }
        await MainActor.run {
            negotiatedService.handleSharedClipboardStatus(enabledMessage)
            #expect(negotiatedService.sharedClipboardEnabled)
        }

        let nonNegotiatedService = await MainActor.run {
            let service = MirageClientService(deviceName: "Legacy Client")
            service.connectionState = .connected(host: "Host")
            return service
        }
        await MainActor.run {
            nonNegotiatedService.handleSharedClipboardStatus(enabledMessage)
            #expect(!nonNegotiatedService.sharedClipboardEnabled)
        }
    }
}
