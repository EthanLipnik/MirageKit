//
//  HostWallpaperHandlingTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/5/26.
//
//  Coverage for inline host wallpaper message handling.
//

@testable import MirageKit
@testable import MirageKitClient
import Loom
import Network
import Foundation
import Testing
import MirageWire

@Suite("Host Wallpaper Handling")
struct HostWallpaperHandlingTests {
    @MainActor
    @Test("Host wallpaper message completes the request from the inline payload")
    func hostWallpaperInlinePayloadCompletesRequest() async throws {
        let service = MirageClientService()
        let hostID = UUID()
        let requestID = UUID()
        let imageData = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let port = try #require(NWEndpoint.Port(rawValue: 9))
        var receivedHostID: UUID?
        var receivedImageData: Data?

        service.connectedHost = LoomPeer(
            id: hostID,
            name: "Host",
            deviceType: .mac,
            endpoint: .hostPort(host: "127.0.0.1", port: port),
            advertisement: LoomPeerAdvertisement(deviceID: hostID)
        )
        service.onHostWallpaperReceived = { sourceHostID, data in
            receivedHostID = sourceHostID
            receivedImageData = data
        }

        let message = MirageWire.HostWallpaperMessage(
            requestID: requestID,
            imageData: imageData,
            pixelWidth: 854,
            pixelHeight: 480
        )
        let envelope = try MirageWire.ControlMessage(type: .hostWallpaper, content: message)

        try await withCheckedThrowingContinuation { continuation in
            service.hostWallpaperRequestID = requestID
            service.hostWallpaperContinuation = continuation
            service.handleHostWallpaper(envelope)
        }

        #expect(receivedHostID == hostID)
        #expect(receivedImageData == imageData)
        #expect(service.hostWallpaperRequestID == nil)
        #expect(service.hostWallpaperContinuation == nil)
    }
}
