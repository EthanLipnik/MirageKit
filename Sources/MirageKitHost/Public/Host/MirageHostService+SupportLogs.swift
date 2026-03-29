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
        do {
            let request = try message.decode(HostSupportLogArchiveRequestMessage.self)

            guard let hostSupportLogArchiveProvider else {
                let response = HostSupportLogArchiveMessage(
                    requestID: request.requestID,
                    errorMessage: "Host log export is unavailable."
                )
                try await clientContext.send(.hostSupportLogArchive, content: response)
                MirageLogger.host("Host support log archive request rejected: provider unavailable")
                return
            }

            let archiveURL = try await hostSupportLogArchiveProvider()
            let response = HostSupportLogArchiveMessage(
                requestID: request.requestID,
                fileName: archiveURL.lastPathComponent
            )
            try await clientContext.send(.hostSupportLogArchive, content: response)

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
            MirageLogger.error(.host, error: error, message: "Failed to handle host support log archive request: ")
            let requestID = (try? message.decode(HostSupportLogArchiveRequestMessage.self))?.requestID
            let response = HostSupportLogArchiveMessage(
                requestID: requestID,
                errorMessage: "Failed to export host logs."
            )
            try? await clientContext.send(.hostSupportLogArchive, content: response)
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
            MirageLogger.error(.host, error: error, message: "Failed host support log Loom transfer: ")
        }
    }

    private func validateExistingClientTransferSession(
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

    private func terminalProgress(
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
