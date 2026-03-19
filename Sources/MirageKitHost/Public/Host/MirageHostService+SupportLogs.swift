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
import Network

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
            let listener = try await startHostSupportLogTransferListener(
                requestID: request.requestID,
                archiveURL: archiveURL,
                expectedClient: clientContext.client
            )

            let transportKind = listener.transportKind
            let port = await listener.port
            let response = HostSupportLogArchiveMessage(
                requestID: request.requestID,
                fileName: archiveURL.lastPathComponent,
                transportKind: transportKind,
                port: port
            )
            try await clientContext.send(.hostSupportLogArchive, content: response)

            Task {
                try? await Task.sleep(for: .seconds(300))
                await listener.stop()
                try? FileManager.default.removeItem(at: archiveURL)
            }

            MirageLogger.host(
                "Prepared host support log Loom transfer requestID=\(request.requestID.uuidString.lowercased()) " +
                    "port=\(port) filename=\(archiveURL.lastPathComponent)"
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

    private func makeHostSupportLogTransferHelloRequest() throws -> LoomSessionHelloRequest {
        LoomSessionHelloRequest(
            deviceID: hostID,
            deviceName: serviceName,
            deviceType: .mac,
            advertisement: advertisedPeerAdvertisement
        )
    }

    private func handleHostSupportLogTransferSession(
        _ session: LoomAuthenticatedSession,
        requestID: UUID,
        archiveURL: URL,
        listener: MirageHostSupportLogTransferListener,
        expectedClient: MirageConnectedClient
    ) async {
        defer {
            Task {
                await listener.stop()
                await session.cancel()
                try? FileManager.default.removeItem(at: archiveURL)
            }
        }

        do {
            try await validateHostSupportLogTransferSession(
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

    private func validateHostSupportLogTransferSession(
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

    private func startHostSupportLogTransferListener(
        requestID: UUID,
        archiveURL: URL,
        expectedClient: MirageConnectedClient
    ) async throws -> MirageHostSupportLogTransferListener {
        let transportKind: LoomTransportKind = .udp
        let parameters = makeHostSupportLogTransferParameters()
        let listener = try NWListener(using: parameters, on: .any)
        let transferListener = MirageHostSupportLogTransferListener(
            listener: listener,
            transportKind: transportKind
        )

        listener.newConnectionHandler = { [weak self, transferListener] connection in
            Task { @MainActor [weak self] in
                guard let self else {
                    connection.cancel()
                    return
                }

                let session = loomNode.makeAuthenticatedSession(
                    connection: connection,
                    role: .receiver,
                    transportKind: transportKind
                )

                do {
                    let identityManager = self.identityManager ?? MirageKit.identityManager
                    let hello = try self.makeHostSupportLogTransferHelloRequest()
                    _ = try await session.start(
                        localHello: hello,
                        identityManager: identityManager,
                        trustProvider: self.trustProvider
                    )
                    await self.handleHostSupportLogTransferSession(
                        session,
                        requestID: requestID,
                        archiveURL: archiveURL,
                        listener: transferListener,
                        expectedClient: expectedClient
                    )
                } catch {
                    MirageLogger.error(
                        .host,
                        error: error,
                        message: "Rejected host support log transfer connection: "
                    )
                    await session.cancel()
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            let continuationBox = ContinuationBox<MirageHostSupportLogTransferListener>(continuation)

            listener.stateUpdateHandler = { [transferListener] state in
                switch state {
                case .ready:
                    guard let boundPort = listener.port?.rawValue else {
                        continuationBox.resume(
                            throwing: MirageError.protocolError("Host support log Loom listener missing port")
                        )
                        return
                    }

                    Task {
                        await transferListener.setPort(boundPort)
                        continuationBox.resume(returning: transferListener)
                    }

                case let .failed(error):
                    continuationBox.resume(throwing: error)

                case .cancelled:
                    continuationBox.resume(
                        throwing: MirageError.protocolError("Host support log Loom listener cancelled")
                    )

                default:
                    break
                }
            }

            listener.start(queue: .global(qos: .userInitiated))
        }
    }

    private func makeHostSupportLogTransferParameters() -> NWParameters {
        let parameters = NWParameters.udp
        parameters.includePeerToPeer = networkConfig.enablePeerToPeer
        parameters.serviceClass = .signaling
        return parameters
    }
}

private actor MirageHostSupportLogTransferListener {
    let transportKind: LoomTransportKind
    private(set) var port: UInt16 = 0

    private let listener: NWListener

    init(
        listener: NWListener,
        transportKind: LoomTransportKind
    ) {
        self.listener = listener
        self.transportKind = transportKind
    }

    func setPort(_ port: UInt16) {
        self.port = port
    }

    func stop() {
        listener.cancel()
    }
}
#endif
