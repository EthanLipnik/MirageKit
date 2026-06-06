//
//  MirageHostService+ConnectionBootstrap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation
import Loom
import Network

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Runs one bootstrap phase with a timeout so unauthenticated sessions cannot hang setup forever.
    func awaitBootstrapStep<T: Sendable>(
        timeout: Duration,
        peerName: String,
        phase: String,
        operation: @escaping @MainActor @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw MirageCore.MirageError.protocolError("Timed out waiting for \(phase) from \(peerName)")
            }

            let result = try await group.next() ?? {
                throw MirageCore.MirageError.protocolError("Bootstrap step ended unexpectedly")
            }()
            group.cancelAll()
            return result
        }
    }

    /// Receives the first Mirage bootstrap request frame from a newly accepted control channel.
    func receiveBootstrapRequest(
        from controlChannel: MirageControlChannel
    ) async throws -> MirageWire.MirageSessionBootstrapRequest {
        var buffer = Data()

        for await chunk in controlChannel.incomingBytes {
            guard !chunk.isEmpty else { continue }
            buffer.append(chunk)

            switch MirageWire.ControlMessage.deserialize(from: buffer) {
            case let .success(message, _):
                guard message.type == .sessionBootstrapRequest else {
                    throw MirageCore.MirageError.protocolError("Expected Mirage session bootstrap request")
                }
                return try message.decode(MirageWire.MirageSessionBootstrapRequest.self)
            case .needMoreData:
                continue
            case let .invalidFrame(reason):
                MirageLogger.host("Rejected incompatible Mirage bootstrap frame: \(reason)")
                throw MirageCore.MirageError.connectionRejected(
                    MirageCore.MirageConnectionRejection(
                        reason: .malformedBootstrap,
                        recoveryHint: "Invalid Mirage bootstrap frame: \(reason)"
                    )
                )
            }
        }

        throw MirageCore.MirageError.protocolError("Control stream closed before session bootstrap request")
    }

    /// Builds the accepted or rejected Mirage bootstrap response for a client request.
    func makeBootstrapResponse(
        for request: MirageWire.MirageSessionBootstrapRequest,
        peerIdentity: LoomPeerIdentity,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?,
        autoTrustGranted: Bool
    ) async throws -> (response: MirageWire.MirageSessionBootstrapResponse, mediaSecurity: MirageMediaSecurityContext?) {
        let hostName = serviceName
        let hostCapabilities = MirageRuntimeCapabilities.currentMosaicCutover

        guard request.protocolVersion == Int(MirageKit.controlProtocolVersion) else {
            return (
                MirageWire.MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: hostName,
                    mediaEncryptionEnabled: false,
                    datagramRegistrationToken: Data(),
                    rejectionReason: .protocolVersionMismatch,
                    protocolMismatchHostVersion: Int(MirageKit.controlProtocolVersion),
                    protocolMismatchClientVersion: request.protocolVersion
                ),
                nil
            )
        }

        guard hostCapabilities.selectedMediaPacketFamilyForSend(
            matching: request.clientCapabilities,
            requiredTopology: .mosaic
        ) != nil else {
            return (
                MirageWire.MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: hostName,
                    mediaEncryptionEnabled: false,
                    datagramRegistrationToken: Data(),
                    hostCapabilities: hostCapabilities,
                    rejectionReason: .protocolVersionMismatch,
                    protocolMismatchHostVersion: Int(MirageKit.controlProtocolVersion),
                    protocolMismatchClientVersion: request.protocolVersion
                ),
                nil
            )
        }

        guard let identityManager else {
            throw MirageCore.MirageError.protocolError("Cannot bootstrap session without identity manager")
        }
        guard let clientPublicKey = peerIdentity.identityPublicKey,
              let clientKeyID = peerIdentity.identityKeyID else {
            throw MirageCore.MirageError.protocolError("Authenticated Loom session is missing client identity metadata")
        }

        let hostIdentity = try MirageKit.currentIdentitySnapshot(using: identityManager)
        let mediaEncryptionEnabled = mediaEncryptionEnabledForAcceptedSession(
            isPeerToPeer: ClientContext.isPeerToPeerConnection(
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot
            ),
            clientRequiresMediaEncryption: request.clientRequiresMediaEncryption
        )
        let datagramRegistrationToken = MirageMediaSecurity.makeRegistrationToken()
        let mediaSecurity = try MirageMediaSecurity.deriveContextForAuthenticatedSession(
            identityManager: identityManager,
            peerPublicKey: clientPublicKey,
            hostID: hostID,
            clientID: peerIdentity.deviceID,
            hostKeyID: hostIdentity.keyID,
            clientKeyID: clientKeyID,
            datagramRegistrationToken: datagramRegistrationToken
        )

        let response = MirageWire.MirageSessionBootstrapResponse(
            accepted: true,
            hostID: hostID,
            hostName: hostName,
            mediaEncryptionEnabled: mediaEncryptionEnabled,
            datagramRegistrationToken: datagramRegistrationToken,
            autoTrustGranted: autoTrustGranted,
            remoteAccessAllowed: MirageConnectivity.MiragePeerAdvertisementMetadata.vpnAccessEnabled(in: advertisedPeerAdvertisement),
            hostCapabilities: hostCapabilities,
            adaptiveGovernorRevision: MirageAdaptiveGovernorProtocol.revision,
            hostOwnedRuntimeSupport: true,
            adaptiveFeedbackClassesSupported: acceptedAdaptiveFeedbackClasses(for: request),
            adaptiveLegacyFallbackMode: MirageAdaptiveGovernorProtocol.legacyFallbackMode
        )
        return (response, mediaSecurity)
    }

    private func acceptedAdaptiveFeedbackClasses(for request: MirageSessionBootstrapRequest) -> [String] {
        guard let requested = request.adaptiveFeedbackClassesSupported,
              !requested.isEmpty else {
            return MirageAdaptiveGovernorProtocol.feedbackClasses
        }
        let supported = Set(MirageAdaptiveGovernorProtocol.feedbackClasses)
        let accepted = requested.filter { supported.contains($0) }
        return accepted.isEmpty ? MirageAdaptiveGovernorProtocol.feedbackClasses : accepted
    }

    /// Returns whether accepted media streams should be encrypted for a session.
    func mediaEncryptionEnabledForAcceptedSession(
        isPeerToPeer: Bool,
        clientRequiresMediaEncryption: Bool
    ) -> Bool {
        if clientRequiresMediaEncryption { return true }
        guard isPeerToPeer else { return true }
        return networkConfig.requireEncryptedMediaOnLocalNetwork
    }

    /// Returns whether the host is currently installing a software update.
    func hostSoftwareUpdateInstallInProgress() async -> Bool {
        guard let softwareUpdateController else { return false }
        let status = await softwareUpdateController.softwareUpdateStatus(
            forceRefresh: false
        )
        return status.isInstallInProgress
    }

    /// Rejects an authenticated session before it becomes a connected Mirage client.
    func rejectIncomingSession(
        _ session: LoomAuthenticatedSession,
        reason: MirageWire.MirageSessionBootstrapRejectionReason
    ) async {
        do {
            let controlChannel = try await MirageControlChannel.accept(from: session)
            let response = MirageWire.MirageSessionBootstrapResponse(
                accepted: false,
                hostID: hostID,
                hostName: serviceName,
                mediaEncryptionEnabled: false,
                datagramRegistrationToken: Data(),
                rejectionReason: reason
            )
            do {
                try await controlChannel.send(.sessionBootstrapResponse, content: response)
            } catch {
                MirageLogger.error(.host, error: error, message: "Failed to send bootstrap rejection: ")
            }
            await closeBootstrapControlChannel(controlChannel, reason: "pre-bootstrap rejection")
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to accept control channel for pre-bootstrap rejection: ")
            await session.cancel()
        }
    }

    /// Creates a rejected bootstrap response for an already accepted control channel.
    func makeRejectedBootstrapResponse(
        reason: MirageWire.MirageSessionBootstrapRejectionReason,
        authorizationFailureReason: MirageWire.MirageSessionBootstrapAuthorizationFailureReason? = nil
    ) -> MirageWire.MirageSessionBootstrapResponse {
        MirageWire.MirageSessionBootstrapResponse(
            accepted: false,
            hostID: hostID,
            hostName: serviceName,
            mediaEncryptionEnabled: false,
            datagramRegistrationToken: Data(),
            rejectionReason: reason,
            authorizationFailureReason: authorizationFailureReason
        )
    }

    /// Closes a rejected bootstrap control channel and logs transport cleanup failures.
    func closeBootstrapControlChannel(_ controlChannel: MirageControlChannel, reason: String) async {
        do {
            try await controlChannel.closeStream()
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to close bootstrap control channel after \(reason): ")
        }
    }
}
#endif
