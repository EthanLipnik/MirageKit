//
//  MirageRuntimeCapabilitiesTests.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageMedia
import MirageWire
import Testing

@Suite("Mirage Runtime Capabilities")
struct MirageRuntimeCapabilitiesTests {
    @Test("Runtime capabilities round trip with stable value encoding")
    func runtimeCapabilitiesRoundTripWithStableValueEncoding() throws {
        let capabilities = MirageRuntimeCapabilities(
            protocolVersions: [MirageProtocolVersion(260604), MirageProtocolVersion(260605)],
            controlFeatures: [.sharedClipboard, .sessionBootstrap],
            mediaPacketFamilies: [MirageMediaPacketFamily("topology-aware-units"), .fixedHeaderFullFrame],
            mediaTopologies: [.atlas, .singleUnit],
            codecs: [.hevc, .h264],
            inputFeatures: [.keyboard, .pointer],
            diagnosticsFeatures: [.streamMetrics, .supportLogs]
        )

        let encoded = try JSONEncoder().encode(capabilities)
        let encodedText = try #require(String(data: encoded, encoding: .utf8))
        let decoded = try JSONDecoder().decode(MirageRuntimeCapabilities.self, from: encoded)

        #expect(decoded == capabilities)
        #expect(encodedText.contains(#""protocolVersions":[260604,260605]"#))
        #expect(encodedText.contains(#""mediaPacketFamilies":["fixed-header-full-frame","topology-aware-units"]"#))
        #expect(encodedText.contains(#""mediaTopologies":["atlas","singleUnit"]"#))
    }

    @Test("Capability negotiation keeps only mutually supported features")
    func capabilityNegotiationKeepsOnlyMutuallySupportedFeatures() {
        let local = MirageRuntimeCapabilities.fullFrameBaseline(codecs: [.hevc, .h264])
        let remote = MirageRuntimeCapabilities(
            protocolVersions: [.currentControl],
            controlFeatures: [.sessionBootstrap, .streamLifecycle],
            mediaPacketFamilies: [.fixedHeaderFullFrame],
            mediaTopologies: [.singleUnit, .atlas],
            codecs: [.hevc],
            inputFeatures: [.pointer],
            diagnosticsFeatures: [.streamMetrics]
        )

        let negotiated = local.negotiated(with: remote)

        #expect(negotiated.protocolVersions == [.currentControl])
        #expect(negotiated.controlFeatures == [.sessionBootstrap, .streamLifecycle])
        #expect(negotiated.mediaPacketFamilies == [.fixedHeaderFullFrame])
        #expect(negotiated.mediaTopologies == [.singleUnit])
        #expect(negotiated.codecs == [.hevc])
        #expect(negotiated.inputFeatures == [.pointer])
        #expect(negotiated.diagnosticsFeatures == [.streamMetrics])
        #expect(local.preferredMediaPacketFamily(matching: remote) == .fixedHeaderFullFrame)
        #expect(local.selectedMediaPacketFamilyForSend(matching: remote) == .fixedHeaderFullFrame)
    }

    @Test("Unsupported media packet families are not selected")
    func unsupportedMediaPacketFamiliesAreNotSelected() {
        let local = MirageRuntimeCapabilities.fullFrameBaseline(codecs: [.hevc])
        let futureOnlyRemote = MirageRuntimeCapabilities(
            protocolVersions: [.currentControl],
            controlFeatures: [.sessionBootstrap],
            mediaPacketFamilies: [MirageMediaPacketFamily("topology-aware-units")],
            mediaTopologies: [.atlas],
            codecs: [.hevc],
            inputFeatures: [],
            diagnosticsFeatures: []
        )

        #expect(local.negotiated(with: futureOnlyRemote).mediaPacketFamilies.isEmpty)
        #expect(local.preferredMediaPacketFamily(matching: futureOnlyRemote) == nil)
        #expect(local.selectedMediaPacketFamilyForSend(matching: futureOnlyRemote) == nil)
    }

    @Test("Send packet-family selection keeps legacy fixed-header fallback")
    func sendPacketFamilySelectionKeepsLegacyFixedHeaderFallback() {
        let local = MirageRuntimeCapabilities.currentFullFrameBaseline
        let missingStreamLifecycle = MirageRuntimeCapabilities(
            protocolVersions: [.currentControl],
            controlFeatures: [.sessionBootstrap],
            mediaPacketFamilies: [.fixedHeaderFullFrame],
            mediaTopologies: [.singleUnit],
            codecs: [.hevc],
            inputFeatures: [],
            diagnosticsFeatures: []
        )

        #expect(local.selectedMediaPacketFamilyForSend(matching: nil) == .fixedHeaderFullFrame)
        #expect(local.selectedMediaPacketFamilyForSend(matching: missingStreamLifecycle) == nil)
    }

    @Test("Mosaic-only snapshot selects media-unit packet family")
    func mosaicOnlySnapshotSelectsMediaUnitPacketFamily() {
        let local = MirageRuntimeCapabilities.currentMosaicOnly
        let remote = MirageRuntimeCapabilities.currentMosaicOnly

        #expect(local.mediaPacketFamilies == [.mosaicMediaUnit])
        #expect(local.mediaTopologies == [.mosaic])
        #expect(local.selectedMediaPacketFamilyForSend(
            matching: remote,
            requiredTopology: .mosaic
        ) == .mosaicMediaUnit)
    }

    @Test("Combined host snapshot advertises both families and topologies")
    func combinedHostSnapshotAdvertisesBothFamiliesAndTopologies() {
        let host = MirageRuntimeCapabilities.currentCombined
        #expect(host.mediaPacketFamilies == [.fixedHeaderFullFrame, .mosaicMediaUnit])
        #expect(host.mediaTopologies == [.singleUnit, .mosaic])
    }

    @Test("Client snapshot omits Mosaic when not opted in")
    func clientSnapshotOmitsMosaicWhenNotOptedIn() {
        let client = MirageRuntimeCapabilities.client(mosaicEnabled: false, codecs: [.hevc])
        #expect(client.mediaPacketFamilies == [.fixedHeaderFullFrame])
        #expect(client.mediaTopologies == [.singleUnit])
    }

    @Test("Client snapshot includes Mosaic when opted in")
    func clientSnapshotIncludesMosaicWhenOptedIn() {
        let client = MirageRuntimeCapabilities.client(mosaicEnabled: true, codecs: [.hevc])
        #expect(client.mediaPacketFamilies == [.fixedHeaderFullFrame, .mosaicMediaUnit])
        #expect(client.mediaTopologies == [.singleUnit, .mosaic])
    }

    @Test("Combined host selects full-frame for a Classic client")
    func combinedHostSelectsFullFrameForClassicClient() {
        let host = MirageRuntimeCapabilities.currentCombined
        let client = MirageRuntimeCapabilities.client(mosaicEnabled: false, codecs: [.hevc])
        #expect(host.selectedMediaPacketFamilyForSend(matching: client) == .fixedHeaderFullFrame)
    }

    @Test("Combined host selects Mosaic for an opted-in client")
    func combinedHostSelectsMosaicForOptedInClient() {
        let host = MirageRuntimeCapabilities.currentCombined
        let client = MirageRuntimeCapabilities.client(mosaicEnabled: true, codecs: [.hevc])
        #expect(host.selectedMediaPacketFamilyForSend(matching: client) == .mosaicMediaUnit)
    }

    @Test("Bootstrap capabilities preserve legacy payload compatibility")
    func bootstrapCapabilitiesPreserveLegacyPayloadCompatibility() throws {
        let legacyRequest = Data(
            #"{"protocolVersion":260604,"clientRequiresMediaEncryption":true,"requestTakeoverIfBusy":false}"#.utf8
        )
        let legacyResponse = Data(
            #"{"accepted":true,"hostID":"D3D0D7F9-459D-4F06-A786-43F3956315AA","hostName":"Studio Mac","mediaEncryptionEnabled":true,"datagramRegistrationToken":"qrs=","autoTrustGranted":false,"remoteAccessAllowed":false}"#.utf8
        )

        let decodedRequest = try JSONDecoder().decode(MirageWire.MirageSessionBootstrapRequest.self, from: legacyRequest)
        let decodedResponse = try JSONDecoder().decode(MirageWire.MirageSessionBootstrapResponse.self, from: legacyResponse)

        #expect(decodedRequest.clientCapabilities == nil)
        #expect(decodedResponse.hostCapabilities == nil)

        let capabilities = MirageRuntimeCapabilities.fullFrameBaseline(codecs: [.hevc])
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageWireProtocol.currentControlVersion),
            clientRequiresMediaEncryption: true,
            clientCapabilities: capabilities
        )
        let response = MirageWire.MirageSessionBootstrapResponse(
            accepted: true,
            hostID: decodedResponse.hostID,
            hostName: decodedResponse.hostName,
            mediaEncryptionEnabled: true,
            datagramRegistrationToken: Data([0xAA, 0xBB]),
            hostCapabilities: capabilities
        )

        #expect(try JSONDecoder().decode(
            MirageWire.MirageSessionBootstrapRequest.self,
            from: JSONEncoder().encode(request)
        ).clientCapabilities == capabilities)
        #expect(try JSONDecoder().decode(
            MirageWire.MirageSessionBootstrapResponse.self,
            from: JSONEncoder().encode(response)
        ).hostCapabilities == capabilities)
    }

    @Test("Current bootstrap request remains decodable by legacy hosts")
    func currentBootstrapRequestRemainsDecodableByLegacyHosts() throws {
        let request = MirageWire.MirageSessionBootstrapRequest(
            protocolVersion: Int(MirageWireProtocol.currentControlVersion),
            clientRequiresMediaEncryption: true,
            requestTakeoverIfBusy: true,
            clientCapabilities: .currentFullFrameBaseline
        )

        let legacy = try JSONDecoder().decode(
            LegacyBootstrapRequest.self,
            from: JSONEncoder().encode(request)
        )

        #expect(legacy.protocolVersion == Int(MirageWireProtocol.currentControlVersion))
        #expect(legacy.clientRequiresMediaEncryption)
        #expect(legacy.requestTakeoverIfBusy)
    }
}

private struct LegacyBootstrapRequest: Decodable {
    let protocolVersion: Int
    let clientRequiresMediaEncryption: Bool
    let requestTakeoverIfBusy: Bool
}
