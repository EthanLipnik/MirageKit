//
//  MirageHostService+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Host support log archive request handling.
//

import Foundation
import Loom
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleHostSupportLogArchiveRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        let request: HostSupportLogArchiveRequestMessage
        do {
            request = try message.decode(HostSupportLogArchiveRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host support log archive request: ")
            return
        }

        do {
            guard let hostSupportLogArchiveProvider else {
                let response = HostSupportLogArchiveMessage(
                    requestID: request.requestID,
                    errorMessage: "Host log export is unavailable."
                )
                do {
                    try await clientContext.send(.hostSupportLogArchive, content: response)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Host support log archive unavailable response",
                        sessionID: clientContext.sessionID
                    )
                }
                MirageLogger.host("Host support log archive request rejected: provider unavailable")
                return
            }

            let archiveURL = try await hostSupportLogArchiveProvider()
            let response = HostSupportLogArchiveMessage(
                requestID: request.requestID,
                fileName: archiveURL.lastPathComponent
            )
            do {
                try await clientContext.send(.hostSupportLogArchive, content: response)
            } catch {
                try? FileManager.default.removeItem(at: archiveURL)
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host support log archive response",
                    sessionID: clientContext.sessionID
                )
                return
            }

            Task { @MainActor [weak self] in
                await self?.handleHostSupportLogTransfer(
                    clientContext.controlChannel.session,
                    requestID: request.requestID,
                    archiveURL: archiveURL,
                    expectedClient: clientContext.client
                )
            }

            MirageLogger.host(
                "Prepared host support log Loom transfer requestID=\(request.requestID.uuidString.lowercased()) " +
                    "filename=\(archiveURL.lastPathComponent)"
            )
        } catch {
            if isExpectedLifecycleControlSendFailure(error) ||
                LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                MirageLogger.host(
                    "Host support log archive request did not complete: \(error.localizedDescription)"
                )
            } else {
                MirageLogger.error(.host, error: error, message: "Failed to handle host support log archive request: ")
            }
            let errorMessage = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
            let response = HostSupportLogArchiveMessage(
                requestID: request.requestID,
                errorMessage: errorMessage.isEmpty ? "Failed to export host logs." : errorMessage
            )
            do {
                try await clientContext.send(.hostSupportLogArchive, content: response)
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host support log archive failure response",
                    sessionID: clientContext.sessionID
                )
            }
        }
    }

    private func handleHostSupportLogTransfer(
        _ session: LoomAuthenticatedSession,
        requestID: UUID,
        archiveURL: URL,
        expectedClient: MirageConnectedClient
    ) async {
        defer {
            Task {
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }

        do {
            try await validateExistingClientTransferSession(
                session,
                expectedClient: expectedClient
            )

            let source = try LoomFileTransferSource(url: archiveURL)
            let byteLength = await source.byteLength
            let engine = LoomTransferEngine(session: session)
            let outgoing = try await engine.offerTransfer(
                LoomTransferOffer(
                    logicalName: archiveURL.lastPathComponent,
                    byteLength: byteLength,
                    contentType: "application/zip",
                    metadata: [
                        "mirage.transfer-kind": "host-support-log-archive",
                        "mirage.request-id": requestID.uuidString.lowercased(),
                    ]
                ),
                source: source
            )

            let terminalProgress = await terminalProgress(from: outgoing.progressEvents)
            switch terminalProgress?.state {
            case .completed:
                break
            case .cancelled, .declined:
                MirageLogger.host(
                    "Host support log Loom transfer ended before completion requestID=\(requestID.uuidString.lowercased()) " +
                        "state=\(terminalProgress?.state.rawValue ?? "unknown")"
                )
                return
            default:
                throw MirageError.protocolError("Host support log Loom transfer did not complete")
            }

            MirageLogger.host(
                "Completed host support log Loom transfer requestID=\(requestID.uuidString.lowercased()) " +
                    "bytes=\(byteLength)"
            )
        } catch {
            if isExpectedLifecycleControlSendFailure(error) ||
                LoomDiagnosticsActionability.isLikelyUserDependent(error: error) {
                MirageLogger.host(
                    "Host support log Loom transfer ended without completion: \(error.localizedDescription)"
                )
            } else {
                MirageLogger.error(.host, error: error, message: "Failed host support log Loom transfer: ")
            }
        }
    }

    func validateExistingClientTransferSession(
        _ session: LoomAuthenticatedSession,
        expectedClient: MirageConnectedClient
    ) async throws {
        guard let context = await session.context else {
            throw MirageError.protocolError("Missing Loom transfer session context")
        }
        if let expectedKeyID = expectedClient.identityKeyID,
           context.peerIdentity.identityKeyID != expectedKeyID {
            throw MirageError.protocolError("Client identity mismatch for Loom transfer session")
        }
        if context.peerIdentity.deviceID != expectedClient.id {
            throw MirageError.protocolError("Client device mismatch for Loom transfer session")
        }
    }

    func terminalProgress(
        from stream: AsyncStream<LoomTransferProgress>
    ) async -> LoomTransferProgress? {
        var lastProgress: LoomTransferProgress?
        for await progress in stream {
            lastProgress = progress
            switch progress.state {
            case .completed, .cancelled, .failed, .declined:
                return progress
            case .offered, .waitingForAcceptance, .transferring:
                break
            }
        }
        return lastProgress
    }
}
#endif
