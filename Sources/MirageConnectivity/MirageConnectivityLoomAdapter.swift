//
//  MirageConnectivityLoomAdapter.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageIdentity
import MirageMedia
import Network

package enum MirageConnectivityLoomAdapter {
    static func loomTransportKind(from kind: MirageTransportKind) -> LoomTransportKind {
        switch kind {
        case .tcp:
            .tcp
        case .quic:
            .quic
        case .udp:
            .udp
        }
    }

    package static func transportKind(from kind: LoomTransportKind) -> MirageTransportKind {
        switch kind {
        case .tcp:
            .tcp
        case .quic:
            .quic
        case .udp:
            .udp
        }
    }

    package static func sessionBootstrapPhase(
        from phase: LoomAuthenticatedSessionBootstrapPhase
    ) -> MirageSessionBootstrapPhase {
        switch phase {
        case .idle:
            .idle
        case .transportStarting:
            .transportStarting
        case .transportReady:
            .transportReady
        case .localHelloSent:
            .localHelloSent
        case .remoteHelloReceived:
            .remoteHelloReceived
        case .trustPendingApproval:
            .trustPendingApproval
        case .ready:
            .ready
        }
    }

    package static func sessionBootstrapProgress(
        from progress: LoomAuthenticatedSessionBootstrapProgress
    ) -> MirageSessionBootstrapProgress {
        MirageSessionBootstrapProgress(
            phase: sessionBootstrapPhase(from: progress.phase),
            failureReason: progress.failureReason
        )
    }

    static func loomDirectPathKind(from kind: MirageDirectPathKind) -> LoomDirectPathKind {
        switch kind {
        case .wired:
            .wired
        case .wifi:
            .wifi
        case .proximityWireless:
            .awdl
        case .other:
            .other
        }
    }

    static func directPathKind(from kind: LoomDirectPathKind?) -> MirageDirectPathKind? {
        switch kind {
        case .wired:
            .wired
        case .wifi:
            .wifi
        case .awdl:
            .proximityWireless
        case .other:
            .other
        case nil:
            nil
        }
    }

    static func deviceType(from deviceType: DeviceType?) -> MirageIdentity.MirageDeviceType? {
        switch deviceType {
        case .mac:
            .mac
        case .iPad:
            .iPad
        case .iPhone:
            .iPhone
        case .vision:
            .vision
        case .unknown:
            .unknown
        case nil:
            nil
        }
    }

    static func serviceClass(from serviceClass: MirageDatagramServiceClass) -> NWParameters.ServiceClass {
        switch serviceClass {
        case .bestEffort:
            .bestEffort
        case .background:
            .background
        case .interactiveVideo:
            .interactiveVideo
        case .interactiveVoice:
            .interactiveVoice
        case .responsiveData:
            .responsiveData
        case .signaling:
            .signaling
        }
    }

    static func serviceClass(from description: String?) -> MirageDatagramServiceClass? {
        switch description {
        case "best-effort":
            .bestEffort
        case "background":
            .background
        case "interactive-video":
            .interactiveVideo
        case "interactive-voice":
            .interactiveVoice
        case "responsive-data":
            .responsiveData
        case "signaling":
            .signaling
        default:
            nil
        }
    }

    static func loomDirectConnectionPolicy(
        from policy: MirageDirectConnectionPolicy
    ) -> LoomDirectConnectionPolicy {
        LoomDirectConnectionPolicy(
            preferredLocalPathOrder: policy.preferredLocalPathOrder.map(loomDirectPathKind(from:)),
            preferredTransportOrder: policy.preferredTransportOrder.map(loomTransportKind(from:)),
            localDiscoveryHostOverride: policy.localDiscoveryHostOverride,
            racesLocalCandidates: policy.racesLocalCandidates,
            racesRemoteCandidates: policy.racesRemoteCandidates
        )
    }

    static func loomNetworkConfiguration(
        from configuration: MirageNetworkConfiguration
    ) -> LoomNetworkConfiguration {
        LoomNetworkConfiguration(
            serviceType: configuration.serviceType,
            controlPort: configuration.controlPort,
            dataPort: configuration.dataPort,
            quicPort: configuration.quicPort,
            udpPort: configuration.udpPort,
            overlayProbePort: configuration.overlayProbePort,
            maxPacketSize: configuration.maxPacketSize,
            enableBonjour: configuration.enableBonjour,
            enablePeerToPeer: configuration.enablePeerToPeer,
            requireEncryptedMediaOnLocalNetwork: configuration.requireEncryptedMediaOnLocalNetwork,
            enabledDirectTransports: Set(configuration.enabledDirectTransports.map(loomTransportKind(from:))),
            directConnectionPolicy: loomDirectConnectionPolicy(from: configuration.directConnectionPolicy),
            quicALPN: configuration.quicALPN,
            directDatagramServiceClass: serviceClass(from: configuration.datagramServiceClass)
        )
    }

    package static func resolvedClientNetworkConfiguration(
        from configuration: LoomNetworkConfiguration
    ) -> LoomNetworkConfiguration {
        var resolvedConfiguration = configuration
        if resolvedConfiguration.serviceType == Loom.serviceType {
            resolvedConfiguration.serviceType = MirageNetworkConfiguration.default.serviceType
        }
        resolvedConfiguration.quicALPN = MirageNetworkConfiguration.default.quicALPN
        return resolvedConfiguration
    }

    static func loomMediaSendProfile(
        from profile: MirageMedia.MirageMediaSendProfile
    ) -> LoomQueuedUnreliableSendProfile {
        switch profile {
        case .interactiveMedia:
            .interactiveMedia
        case .proximityInteractiveMedia:
            .proximityInteractiveMedia
        case .proximityRealtimeDisplay:
            .proximityRealtimeDisplay
        case .proximityRealtimeDisplaySingleLane:
            .proximityRealtimeDisplaySingleLane
        case .interactiveAudio:
            .interactiveAudio
        case .proximityInteractiveAudio:
            .proximityInteractiveAudio
        case .priorityInputRealtime:
            .priorityInputRealtime
        case .priorityInputRealtimeSequenced:
            .priorityInputRealtimeSequenced
        case .priorityInputContinuous:
            .priorityInputContinuous
        case .priorityInputProtected:
            .priorityInputProtected
        case .throughputProbe:
            .throughputProbe
        }
    }

    static func mediaSendProfile(
        from profile: LoomQueuedUnreliableSendProfile
    ) -> MirageMedia.MirageMediaSendProfile {
        switch profile {
        case .interactiveMedia:
            .interactiveMedia
        case .proximityInteractiveMedia:
            .proximityInteractiveMedia
        case .proximityRealtimeDisplay:
            .proximityRealtimeDisplay
        case .proximityRealtimeDisplaySingleLane:
            .proximityRealtimeDisplaySingleLane
        case .interactiveAudio:
            .interactiveAudio
        case .proximityInteractiveAudio:
            .proximityInteractiveAudio
        case .priorityInputRealtime:
            .priorityInputRealtime
        case .priorityInputRealtimeSequenced:
            .priorityInputRealtimeSequenced
        case .priorityInputContinuous:
            .priorityInputContinuous
        case .priorityInputProtected:
            .priorityInputProtected
        case .throughputProbe:
            .throughputProbe
        }
    }

    static func directTransportDescriptor(
        from transport: LoomDirectTransportAdvertisement
    ) -> MirageDirectTransportDescriptor {
        MirageDirectTransportDescriptor(
            kind: transportKind(from: transport.transportKind),
            port: transport.port,
            pathKind: directPathKind(from: transport.pathKind)
        )
    }

    static func peerDescriptor(
        from peer: LoomPeer,
        targetSource: MirageConnectivityTargetSource = .bonjour
    ) -> MiragePeerDescriptor {
        MiragePeerDescriptor(
            deviceID: peer.id.deviceID,
            appID: peer.id.appID,
            name: peer.name,
            deviceType: deviceType(from: peer.deviceType),
            endpointDescription: String(describing: peer.endpoint),
            protocolVersion: MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from: peer.advertisement),
            identityKeyID: peer.advertisement.identityKeyID,
            directTransports: peer.advertisement.directTransports.map(directTransportDescriptor(from:)),
            targetSource: targetSource
        )
    }

    static func peerDescriptor(
        from identity: LoomPeerIdentity,
        advertisement: LoomPeerAdvertisement?,
        targetSource: MirageConnectivityTargetSource = .unknown
    ) -> MiragePeerDescriptor {
        MiragePeerDescriptor(
            deviceID: identity.deviceID,
            name: identity.name,
            deviceType: deviceType(from: identity.deviceType),
            endpointDescription: identity.endpoint,
            protocolVersion: advertisement.map(MiragePeerAdvertisementMetadata.discoveryProtocolVersion(from:)),
            identityKeyID: identity.identityKeyID ?? advertisement?.identityKeyID,
            directTransports: advertisement?.directTransports.map(directTransportDescriptor(from:)) ?? [],
            targetSource: targetSource
        )
    }

    static func transportPathStatus(
        from status: LoomSessionNetworkPathStatus
    ) -> MirageTransportPathStatus {
        switch status {
        case .satisfied:
            .satisfied
        case .unsatisfied:
            .unsatisfied
        case .requiresConnection:
            .requiresConnection
        }
    }

    static func transportPathSnapshot(
        from snapshot: LoomSessionNetworkPathSnapshot?,
        selectedTransport: MirageTransportKind?,
        targetSource: MirageConnectivityTargetSource = .unknown,
        diagnostics: LoomTransportDiagnostics? = nil,
        dropCounts: MirageConnectivityDropCounts = MirageConnectivityDropCounts(),
        firstControlMessageMs: Double? = nil,
        firstMediaPacketMs: Double? = nil
    ) -> MirageTransportPathSnapshot? {
        guard let snapshot else { return nil }
        return MirageTransportPathSnapshot(
            status: transportPathStatus(from: snapshot.status),
            interfaceNames: snapshot.interfaceNames,
            isExpensive: snapshot.isExpensive,
            isConstrained: snapshot.isConstrained,
            supportsIPv4: snapshot.supportsIPv4,
            supportsIPv6: snapshot.supportsIPv6,
            usesWiFi: snapshot.usesWiFi,
            usesWiredEthernet: snapshot.usesWiredEthernet,
            usesCellular: snapshot.usesCellular,
            usesLoopback: snapshot.usesLoopback,
            usesOther: snapshot.usesOther,
            selectedTransport: selectedTransport,
            targetSource: targetSource,
            receiveSemantics: diagnostics?.receiveSemantics,
            serviceClass: serviceClass(from: diagnostics?.serviceClass),
            usableDatagramSize: diagnostics?.usableDatagramSize,
            dropCounts: dropCounts,
            firstControlMessageMs: firstControlMessageMs,
            firstMediaPacketMs: firstMediaPacketMs
        )
    }
}

actor LoomMirageConnectivitySession: MirageConnectivitySession {
    private let session: LoomAuthenticatedSession
    private let selectedTransportKind: MirageTransportKind
    private let targetSource: MirageConnectivityTargetSource

    nonisolated var id: UUID { session.id }

    init(
        session: LoomAuthenticatedSession,
        selectedTransport: LoomTransportKind,
        targetSource: MirageConnectivityTargetSource = .unknown
    ) {
        self.session = session
        selectedTransportKind = MirageConnectivityLoomAdapter.transportKind(from: selectedTransport)
        self.targetSource = targetSource
    }

    var selectedTransport: MirageTransportKind {
        selectedTransportKind
    }

    var transportPathSnapshot: MirageTransportPathSnapshot? {
        get async {
            await MirageConnectivityLoomAdapter.transportPathSnapshot(
                from: session.pathSnapshot,
                selectedTransport: selectedTransport,
                targetSource: targetSource,
                diagnostics: session.context?.transportDiagnostics
            )
        }
    }

    var peerDescriptor: MiragePeerDescriptor? {
        get async {
            guard let context = await session.context else { return nil }
            return MirageConnectivityLoomAdapter.peerDescriptor(
                from: context.peerIdentity,
                advertisement: context.peerAdvertisement,
                targetSource: targetSource
            )
        }
    }

    func makeTransportPathObserver() async -> AsyncStream<MirageTransportPathSnapshot> {
        let pathObserver = await session.makePathObserver()
        let selectedTransport = selectedTransport
        let targetSource = targetSource
        let session = session
        return AsyncStream { continuation in
            let task = Task {
                for await snapshot in pathObserver {
                    let diagnostics = await session.context?.transportDiagnostics
                    let projected = MirageConnectivityLoomAdapter.transportPathSnapshot(
                        from: snapshot,
                        selectedTransport: selectedTransport,
                        targetSource: targetSource,
                        diagnostics: diagnostics
                    )
                    if let projected {
                        continuation.yield(projected)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func close() async throws {
        await session.cancel()
    }
}
