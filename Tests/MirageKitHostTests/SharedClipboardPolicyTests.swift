//
//  SharedClipboardPolicyTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/11/26.
//

#if os(macOS)
@testable import MirageKitHost
import Foundation
import MirageKit
import Testing

@Suite("Host Shared Clipboard Policy")
struct SharedClipboardPolicyTests {
    @Test("Host registers shared clipboard update handler")
    func registersSharedClipboardHandler() async {
        let service = await MainActor.run { MirageHostService(hostName: "Test Host", deviceID: UUID()) }
        await MainActor.run {
            #expect(service.controlMessageHandlers[.sharedClipboardUpdate] != nil)
        }
    }

    @Test("Host shared clipboard feature negotiation gate")
    func hostSharedClipboardFeatureNegotiation() {
        #expect(MirageHostService.sharedClipboardFeatureNegotiated([.sharedClipboardV1]))
        #expect(!MirageHostService.sharedClipboardFeatureNegotiated([]))
    }

    @Test("Host shared clipboard requires toggle ready session and active stream")
    func hostSharedClipboardActivationPolicy() {
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: false,
                negotiatedFeatures: [.sharedClipboardV1],
                sessionState: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                negotiatedFeatures: [.sharedClipboardV1],
                sessionState: .credentialsRequired,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                negotiatedFeatures: [.sharedClipboardV1],
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                negotiatedFeatures: [.sharedClipboardV1],
                sessionState: .ready,
                hasAppStreams: true,
                hasDesktopStream: false
            )
        )
        #expect(
            MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                negotiatedFeatures: [.sharedClipboardV1],
                sessionState: .ready,
                hasAppStreams: false,
                hasDesktopStream: true
            )
        )
    }

    @Test("Host shared clipboard rejects runtime without negotiated support")
    func hostSharedClipboardRejectsMissingFeature() {
        #expect(
            !MirageHostService.shouldEnableSharedClipboard(
                settingEnabled: true,
                negotiatedFeatures: [],
                sessionState: .ready,
                hasAppStreams: true,
                hasDesktopStream: true
            )
        )
    }
}
#endif
