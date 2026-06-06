//
//  HostProtocolVersionRejectionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/4/26.
//

import Foundation
@testable import MirageKit
@testable import MirageKitHost
import Loom
import Testing
import MirageKit
import MirageWire

#if os(macOS)
@Suite("Host Protocol Version Rejection")
struct HostProtocolVersionRejectionTests {
    @MainActor
    @Test("Stale bootstrap protocol is rejected before session setup")
    func staleBootstrapProtocolIsRejectedBeforeSessionSetup() async throws {
        let hostID = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
        let staleProtocolVersion = Int(MirageKit.controlProtocolVersion) - 1
        let host = MirageHostService(hostName: "Version Host", deviceID: hostID)
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: staleProtocolVersion,
            clientRequiresMediaEncryption: true
        )
        let peer = LoomPeerIdentity(
            deviceID: try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000002")),
            name: "Old iPad",
            deviceType: .iPad,
            iCloudUserID: nil,
            identityKeyID: nil,
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )

        let result = try await host.makeBootstrapResponse(
            for: request,
            peerIdentity: peer,
            remoteEndpoint: nil,
            pathSnapshot: nil,
            autoTrustGranted: false
        )

        #expect(!result.response.accepted)
        #expect(result.response.hostID == hostID)
        #expect(result.response.rejectionReason == .protocolVersionMismatch)
        #expect(result.response.protocolMismatchHostVersion == Int(MirageKit.controlProtocolVersion))
        #expect(result.response.protocolMismatchClientVersion == staleProtocolVersion)
        #expect(result.mediaSecurity == nil)
    }

    @MainActor
    @Test("Future bootstrap protocol is rejected before session setup")
    func futureBootstrapProtocolIsRejectedBeforeSessionSetup() async throws {
        let hostID = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000003"))
        let futureProtocolVersion = Int(MirageKit.controlProtocolVersion) + 1
        let host = MirageHostService(hostName: "Version Host", deviceID: hostID)
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: futureProtocolVersion,
            clientRequiresMediaEncryption: true,
            clientCapabilities: .currentFullFrameBaseline
        )

        let result = try await host.makeBootstrapResponse(
            for: request,
            peerIdentity: peerIdentity(),
            remoteEndpoint: nil,
            pathSnapshot: nil,
            autoTrustGranted: false
        )

        #expect(!result.response.accepted)
        #expect(result.response.rejectionReason == .protocolVersionMismatch)
        #expect(result.response.protocolMismatchHostVersion == Int(MirageKit.controlProtocolVersion))
        #expect(result.response.protocolMismatchClientVersion == futureProtocolVersion)
        #expect(result.mediaSecurity == nil)
    }

    @MainActor
    @Test("Unsupported media packet family is rejected before session setup")
    func unsupportedMediaPacketFamilyIsRejectedBeforeSessionSetup() async throws {
        let hostID = try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000004"))
        let host = MirageHostService(hostName: "Version Host", deviceID: hostID)
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageKit.controlProtocolVersion),
            clientRequiresMediaEncryption: true,
            clientCapabilities: MirageRuntimeCapabilities(
                protocolVersions: [.currentControl],
                controlFeatures: [.sessionBootstrap, .streamLifecycle],
                mediaPacketFamilies: [MirageMediaPacketFamily("topology-aware-units")],
                mediaTopologies: [.singleUnit],
                codecs: [.hevc],
                inputFeatures: [],
                diagnosticsFeatures: []
            )
        )

        let result = try await host.makeBootstrapResponse(
            for: request,
            peerIdentity: peerIdentity(),
            remoteEndpoint: nil,
            pathSnapshot: nil,
            autoTrustGranted: false
        )

        #expect(!result.response.accepted)
        #expect(result.response.hostCapabilities?.mediaPacketFamilies == [.mosaicMediaUnit])
        #expect(result.response.hostCapabilities?.mediaTopologies == [.mosaic])
        #expect(result.response.rejectionReason == .protocolVersionMismatch)
        #expect(result.response.protocolMismatchHostVersion == Int(MirageKit.controlProtocolVersion))
        #expect(result.response.protocolMismatchClientVersion == Int(MirageKit.controlProtocolVersion))
        #expect(result.mediaSecurity == nil)
    }

    private func peerIdentity() throws -> LoomPeerIdentity {
        LoomPeerIdentity(
            deviceID: try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000002")),
            name: "Old iPad",
            deviceType: .iPad,
            iCloudUserID: nil,
            identityKeyID: nil,
            identityPublicKey: nil,
            isIdentityAuthenticated: true,
            endpoint: "127.0.0.1"
        )
    }
}
#endif
