//
//  MirageHostService+ConnectionBootstrap.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/13/26.
//

import Foundation
import Loom
import Network
import MirageKit

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
                throw MirageError.protocolError("Timed out waiting for \(phase) from \(peerName)")
            }

            let result = try await group.next() ?? {
                throw MirageError.protocolError("Bootstrap step ended unexpectedly")
            }()
            group.cancelAll()
            return result
        }
    }

    /// Receives the first Mirage bootstrap request frame from a newly accepted control channel.
    func receiveBootstrapRequest(
        from controlChannel: MirageControlChannel
    ) async throws -> MirageSessionBootstrapRequest {
        var buffer = Data()

        for await chunk in controlChannel.incomingBytes {
            guard !chunk.isEmpty else { continue }
            buffer.append(chunk)

            switch ControlMessage.deserialize(from: buffer) {
            case let .success(message, _):
                guard message.type == .sessionBootstrapRequest else {
                    throw MirageError.protocolError("Expected Mirage session bootstrap request")
                }
                return try message.decode(MirageSessionBootstrapRequest.self)
            case .needMoreData:
                continue
            case let .invalidFrame(reason):
                MirageLogger.host("Rejected incompatible Mirage bootstrap frame: \(reason)")
                throw MirageError.connectionRejected(
                    MirageConnectionRejection(
                        reason: .malformedBootstrap,
                        recoveryHint: "Invalid Mirage bootstrap frame: \(reason)"
                    )
                )
            }
        }

        throw MirageError.protocolError("Control stream closed before session bootstrap request")
    }

    /// Builds the accepted or rejected Mirage bootstrap response for a client request.
    func makeBootstrapResponse(
        for request: MirageSessionBootstrapRequest,
        peerIdentity: LoomPeerIdentity,
        remoteEndpoint: NWEndpoint?,
        pathSnapshot: LoomSessionNetworkPathSnapshot?,
        autoTrustGranted: Bool
    ) async throws -> (response: MirageSessionBootstrapResponse, mediaSecurity: MirageMediaSecurityContext?) {
        let hostName = serviceName

        guard request.protocolVersion == Int(MirageKit.protocolVersion) else {
            return (
                MirageSessionBootstrapResponse(
                    accepted: false,
                    hostID: hostID,
                    hostName: hostName,
                    mediaEncryptionEnabled: false,
                    udpRegistrationToken: Data(),
                    rejectionReason: .protocolVersionMismatch,
                    protocolMismatchHostVersion: Int(MirageKit.protocolVersion),
                    protocolMismatchClientVersion: request.protocolVersion
                ),
                nil
            )
        }

        guard let identityManager else {
            throw MirageError.protocolError("Cannot bootstrap session without identity manager")
        }
        guard let clientPublicKey = peerIdentity.identityPublicKey,
              let clientKeyID = peerIdentity.identityKeyID else {
            throw MirageError.protocolError("Authenticated Loom session is missing client identity metadata")
        }

        let hostIdentity = try identityManager.currentIdentity()
        let mediaEncryptionEnabled = mediaEncryptionEnabledForAcceptedSession(
            isPeerToPeer: ClientContext.isPeerToPeerConnection(
                remoteEndpoint: remoteEndpoint,
                pathSnapshot: pathSnapshot
            ),
            clientRequiresMediaEncryption: request.clientRequiresMediaEncryption
        )
        let udpRegistrationToken = MirageMediaSecurity.makeRegistrationToken()
        let mediaSecurity = try MirageMediaSecurity.deriveContextForAuthenticatedSession(
            identityManager: identityManager,
            peerPublicKey: clientPublicKey,
            hostID: hostID,
            clientID: peerIdentity.deviceID,
            hostKeyID: hostIdentity.keyID,
            clientKeyID: clientKeyID,
            udpRegistrationToken: udpRegistrationToken
        )

        let response = MirageSessionBootstrapResponse(
            accepted: true,
            hostID: hostID,
            hostName: hostName,
            mediaEncryptionEnabled: mediaEncryptionEnabled,
            udpRegistrationToken: udpRegistrationToken,
            autoTrustGranted: autoTrustGranted,
            remoteAccessAllowed: MiragePeerAdvertisementMetadata.vpnAccessEnabled(in: advertisedPeerAdvertisement)
        )
        return (response, mediaSecurity)
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
        reason: MirageSessionBootstrapRejectionReason
    ) async {
        do {
            let controlChannel = try await MirageControlChannel.accept(from: session)
            let response = MirageSessionBootstrapResponse(
                accepted: false,
                hostID: hostID,
                hostName: serviceName,
                mediaEncryptionEnabled: false,
                udpRegistrationToken: Data(),
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
        reason: MirageSessionBootstrapRejectionReason
    ) -> MirageSessionBootstrapResponse {
        MirageSessionBootstrapResponse(
            accepted: false,
            hostID: hostID,
            hostName: serviceName,
            mediaEncryptionEnabled: false,
            udpRegistrationToken: Data(),
            rejectionReason: reason
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
