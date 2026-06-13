//
//  HostMediaSendProfileRetuneTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/2/26.
//

@testable import Loom
@testable import MirageKit
@testable import MirageKitHost
import Testing

#if os(macOS)
@Suite("Host Media Send Profile Retune")
struct HostMediaSendProfileRetuneTests {
    @Test("Media send profile reference tracks active retunes")
    func mediaSendProfileReferenceTracksActiveRetunes() async {
        let context = makeContext()
        let reference = await context.setMediaSendProfile(.interactiveMedia)

        #expect(reference.read { $0 } == .interactiveMedia)
        #expect(await context.activeMediaSendProfile() == .interactiveMedia)

        let returnedReference = await context.setMediaSendProfile(.proximityRealtimeDisplay)

        #expect(returnedReference === reference)
        #expect(reference.read { $0 } == .proximityRealtimeDisplay)
        #expect(await context.activeMediaSendProfile() == .proximityRealtimeDisplay)
    }

    @Test("Replacement pipeline snapshot advances token and rebuilds AWDL policy")
    func replacementPipelineSnapshotAdvancesTokenAndRebuildsAwdlPolicy() async {
        let previousContext = makeContext(
            targetFrameRate: 120,
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            maxPacketSize: mirageDirectLocalMaxPacketSize
        )
        let restartSnapshot = await previousContext.desktopPipelineRestartSnapshot
        let previousStartSnapshot = await previousContext.streamStartSnapshot
        let replacementMediaMaxPacketSize = mirageNegotiatedMediaMaxPacketSize(
            requested: previousStartSnapshot.mediaMaxPacketSize,
            mediaPathProfile: .awdlRadio,
            pathKind: .awdl
        )
        let replacementContext = makeContext(
            targetFrameRate: restartSnapshot.encoderConfig.targetFrameRate,
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            maxPacketSize: replacementMediaMaxPacketSize
        )

        await replacementContext.seedReplacementPipelineTokens(
            dimensionToken: restartSnapshot.nextDimensionToken,
            epoch: restartSnapshot.nextEpoch,
            reason: "test-route-class-change"
        )

        let startSnapshot = await replacementContext.streamStartSnapshot
        let mediaPathSnapshot = await replacementContext.streamMediaPathSnapshot

        #expect(startSnapshot.dimensionToken == 1)
        #expect(startSnapshot.targetFrameRate == 60)
        #expect(startSnapshot.mediaMaxPacketSize == mirageDirectProximityMaxPacketSize)
        #expect(mediaPathSnapshot.transportPathKind == .awdl)
        #expect(mediaPathSnapshot.mediaPathProfile == .awdlRadio)
    }

    @Test("Replacement pipeline restores requested latency when leaving AWDL")
    func replacementPipelineRestoresRequestedLatencyWhenLeavingAwdl() async {
        let awdlContext = makeContext(
            transportPathKind: .awdl,
            mediaPathProfile: .awdlRadio,
            latencyMode: .lowestLatency,
            hostBufferingPolicy: .freshestFrame,
            maxPacketSize: mirageDirectProximityMaxPacketSize
        )

        let restartSnapshot = await awdlContext.desktopPipelineRestartSnapshot
        #expect(restartSnapshot.requestedLatencyMode == .lowestLatency)
        #expect(restartSnapshot.latencyMode == .balanced)
        #expect(restartSnapshot.requestedHostBufferingPolicy == .freshestFrame)
        #expect(restartSnapshot.hostBufferingPolicy == .stability)

        let replacementContext = makeContext(
            transportPathKind: .wifi,
            mediaPathProfile: .localWiFi,
            latencyMode: restartSnapshot.requestedLatencyMode,
            hostBufferingPolicy: restartSnapshot.requestedHostBufferingPolicy,
            maxPacketSize: mirageDirectWiFiMaxPacketSize
        )
        let replacementSnapshot = await replacementContext.desktopPipelineRestartSnapshot

        #expect(replacementSnapshot.requestedLatencyMode == .lowestLatency)
        #expect(replacementSnapshot.latencyMode == .lowestLatency)
        #expect(replacementSnapshot.requestedHostBufferingPolicy == .freshestFrame)
        #expect(replacementSnapshot.hostBufferingPolicy == .freshestFrame)
    }

    @Test("Active retune uses stored client AWDL evidence")
    @MainActor
    func activeRetuneUsesStoredClientAwdlEvidence() {
        let host = MirageHostService(hostName: "Retune Evidence Host")
        let startPolicy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .awdl,
            clientMediaPathProfile: .awdlRadio,
            clientPathSignature: "status=satisfied|kind=awdl|media=awdlRadio|if=awdl0"
        )
        host.mediaPathClientEvidenceByStreamID[42] = HostStreamMediaPathClientEvidence(policy: startPolicy)

        let retunePolicy = host.effectiveMediaPathPolicyForActiveMediaRetune(
            hostSnapshot: Self.snapshot(kind: .wifi),
            streamID: 42
        )

        #expect(retunePolicy.transportPathKind == .awdl)
        #expect(retunePolicy.mediaPathProfile == .awdlRadio)
    }

    @Test("Active retune uses stored client LLW evidence as local WiFi")
    @MainActor
    func activeRetuneUsesStoredClientLlwEvidenceAsLocalWiFi() {
        let host = MirageHostService(hostName: "Retune LLW Evidence Host")
        let startPolicy = MirageEffectiveMediaPathPolicy.resolve(
            hostSnapshot: Self.snapshot(kind: .wifi),
            clientPathKind: .awdl,
            clientMediaPathProfile: .awdlRadio,
            clientPathSignature: "status=satisfied|kind=awdl|media=awdlRadio|if=llw0"
        )
        host.mediaPathClientEvidenceByStreamID[42] = HostStreamMediaPathClientEvidence(policy: startPolicy)

        let retunePolicy = host.effectiveMediaPathPolicyForActiveMediaRetune(
            hostSnapshot: Self.snapshot(kind: .wifi),
            streamID: 42
        )

        #expect(retunePolicy.transportPathKind == .wifi)
        #expect(retunePolicy.mediaPathProfile == .localWiFi)
    }

    private func makeContext(
        targetFrameRate: Int = 60,
        transportPathKind: MirageNetworkPathKind = .unknown,
        mediaPathProfile: MirageMediaPathProfile? = nil,
        latencyMode: MirageStreamLatencyMode = .lowestLatency,
        hostBufferingPolicy: MirageHostBufferingPolicy = .freshestFrame,
        maxPacketSize: Int = mirageDefaultMaxPacketSize
    ) -> StreamContext {
        let encoderConfig = MirageEncoderConfiguration(
            targetFrameRate: targetFrameRate,
            keyFrameInterval: 1800,
            colorDepth: .pro,
            colorSpace: .displayP3,
            pixelFormat: .bgr10a2,
            bitrate: 32_000_000
        )
        return StreamContext(
            streamID: 91,
            windowID: 91,
            encoderConfig: encoderConfig,
            streamScale: 1.0,
            maxPacketSize: maxPacketSize,
            latencyMode: latencyMode,
            hostBufferingPolicy: hostBufferingPolicy,
            transportPathKind: transportPathKind,
            mediaPathProfile: mediaPathProfile
        )
    }

    private static func snapshot(kind: MirageNetworkPathKind) -> MirageNetworkPathSnapshot {
        switch kind {
        case .awdl:
            MirageNetworkPathClassifier.classify(
                interfaceNames: ["awdl0"],
                usesWiFi: false,
                usesWired: false,
                usesCellular: false,
                usesLoopback: false,
                usesOther: true,
                status: "satisfied",
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true
            )
        case .wifi:
            MirageNetworkPathClassifier.classify(
                interfaceNames: ["en0"],
                usesWiFi: true,
                usesWired: false,
                usesCellular: false,
                usesLoopback: false,
                usesOther: false,
                status: "satisfied",
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true
            )
        case .wired:
            MirageNetworkPathClassifier.classify(
                interfaceNames: ["en7"],
                usesWiFi: false,
                usesWired: true,
                usesCellular: false,
                usesLoopback: false,
                usesOther: false,
                status: "satisfied",
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true
            )
        case .cellular, .vpn, .loopback, .other, .unknown:
            MirageNetworkPathClassifier.classify(
                interfaceNames: [],
                usesWiFi: false,
                usesWired: false,
                usesCellular: kind == .cellular,
                usesLoopback: kind == .loopback,
                usesOther: kind == .other,
                status: "satisfied",
                isExpensive: false,
                isConstrained: false,
                supportsIPv4: true,
                supportsIPv6: true
            )
        }
    }
}
#endif
