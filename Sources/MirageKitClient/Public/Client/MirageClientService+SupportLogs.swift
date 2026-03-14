//
//  MirageClientService+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Client host-support-log request flow.
//

import Foundation
import Loom
import MirageKit
import Network

#if canImport(UIKit)
import UIKit
#endif

@MainActor
public extension MirageClientService {
    /// Requests a zipped support log archive from the connected host and stores it in a temporary file.
    func requestHostSupportLogArchive() async throws -> URL {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }
        guard hostSupportLogArchiveContinuation == nil else {
            throw MirageError.protocolError("Host log export already in progress")
        }

        let requestID = UUID()
        let request = HostSupportLogArchiveRequestMessage(requestID: requestID)
        let message = try ControlMessage(type: .hostSupportLogArchiveRequest, content: request)
        let data = message.serialize()

        return try await withCheckedThrowingContinuation { continuation in
            hostSupportLogArchiveRequestID = requestID
            hostSupportLogArchiveContinuation = continuation
            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = nil
            hostSupportLogArchiveTimeoutTask?.cancel()
            hostSupportLogArchiveTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.hostSupportLogArchiveTimeout ?? .seconds(30))
                guard let self,
                      self.hostSupportLogArchiveContinuation != nil else {
                    return
                }
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError("Timed out waiting for host support logs"))
                )
            }
            connection.send(content: data, completion: .idempotent)
        }
    }
}

@MainActor
extension MirageClientService {
    func completeHostSupportLogArchiveRequest(_ result: Result<URL, Error>) {
        hostSupportLogArchiveRequestID = nil
        hostSupportLogArchiveTransferTask?.cancel()
        hostSupportLogArchiveTransferTask = nil
        guard let continuation = hostSupportLogArchiveContinuation else { return }
        hostSupportLogArchiveContinuation = nil
        hostSupportLogArchiveTimeoutTask?.cancel()
        hostSupportLogArchiveTimeoutTask = nil
        continuation.resume(with: result)
    }

    func downloadHostSupportLogArchive(
        requestID: UUID,
        fileName: String,
        transportKind: LoomTransportKind,
        port: UInt16
    ) async throws -> URL {
        guard let connectedHost else {
            throw MirageError.protocolError("No connected host")
        }

        let endpoint = try supportLogTransferEndpoint(
            from: connectedHost.endpoint,
            advertisedPort: port
        )
        let hello = try makeSupportLogTransferHelloRequest()
        let session = try await loomNode.connect(
            to: endpoint,
            using: transportKind,
            hello: hello
        )
        defer {
            Task {
                await session.cancel()
            }
        }

        try await validateSupportLogTransferSession(session, connectedHost: connectedHost)

        let transferEngine = LoomTransferEngine(session: session)
        let incomingTransfer = try await requireMatchingHostSupportLogTransfer(
            from: transferEngine,
            requestID: requestID
        )
        let destinationURL = uniqueSupportLogDestinationURL(fileName: fileName)
        let sink = try LoomFileTransferSink(url: destinationURL)
        try await incomingTransfer.accept(using: sink)

        let terminalProgress = await terminalProgress(from: incomingTransfer.progressEvents)
        guard terminalProgress?.state == .completed else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw MirageError.protocolError("Host support log transfer did not complete")
        }

        return destinationURL
    }

    private func makeSupportLogTransferHelloRequest() throws -> LoomSessionHelloRequest {
        let resolvedIdentityManager = identityManager ?? MirageKit.identityManager
        let identity = try resolvedIdentityManager.currentIdentity()
        let advertisement = MiragePeerAdvertisementMetadata.makeClientAdvertisement(
            deviceID: deviceID,
            deviceType: supportLogTransferCurrentDeviceType,
            identityKeyID: identity.keyID
        )
        return LoomSessionHelloRequest(
            deviceID: deviceID,
            deviceName: deviceName,
            deviceType: supportLogTransferCurrentDeviceType,
            advertisement: advertisement
        )
    }

    private var supportLogTransferCurrentDeviceType: DeviceType {
        #if os(macOS)
        .mac
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? .iPad : .iPhone
        #elseif os(visionOS)
        .vision
        #else
        .unknown
        #endif
    }

    private func supportLogTransferEndpoint(
        from endpoint: NWEndpoint,
        advertisedPort: UInt16
    ) throws -> NWEndpoint {
        guard advertisedPort > 0,
              let port = NWEndpoint.Port(rawValue: advertisedPort) else {
            throw MirageError.protocolError("Host returned an invalid Loom transfer port")
        }

        let bonjourHost = {
            if let serviceName = Self.serviceName(from: endpoint) ?? Self.serviceName(from: connection?.endpoint),
               !serviceName.isEmpty {
                return Self.expandedBonjourHosts(for: NWEndpoint.Host(serviceName)).first
            }
            return nil
        }()

        let host = Self.host(from: connection?.currentPath?.remoteEndpoint)
            ?? Self.host(from: endpoint)
            ?? Self.host(from: connection?.endpoint)
            ?? bonjourHost

        guard let host else {
            throw MirageError.protocolError("Connected host endpoint does not support direct Loom transfer")
        }
        return .hostPort(host: host, port: port)
    }

    private func validateSupportLogTransferSession(
        _ session: LoomAuthenticatedSession,
        connectedHost: LoomPeer
    ) async throws {
        guard let context = await session.context else {
            throw MirageError.protocolError("Loom transfer session is missing authenticated context")
        }
        if let expectedKeyID = connectedHostIdentityKeyID ?? expectedHostIdentityKeyID ?? connectedHost.advertisement.identityKeyID,
           context.peerIdentity.identityKeyID != expectedKeyID {
            throw MirageError.protocolError("Loom transfer session host identity mismatch")
        }
        if context.peerIdentity.deviceID != connectedHost.deviceID {
            throw MirageError.protocolError("Loom transfer session host device mismatch")
        }
    }

    private func requireMatchingHostSupportLogTransfer(
        from engine: LoomTransferEngine,
        requestID: UUID
    ) async throws -> LoomIncomingTransfer {
        for await transfer in engine.incomingTransfers {
            guard transfer.offer.metadata["mirage.transfer-kind"] == "host-support-log-archive" else {
                try? await transfer.decline()
                continue
            }
            guard transfer.offer.metadata["mirage.request-id"] == requestID.uuidString.lowercased() else {
                try? await transfer.decline()
                continue
            }
            return transfer
        }
        throw MirageError.protocolError("Host did not offer a matching support log transfer")
    }

    private func uniqueSupportLogDestinationURL(fileName: String) -> URL {
        let sanitized = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitized.isEmpty ? "MirageHostSupportLogs.zip" : URL(fileURLWithPath: sanitized).lastPathComponent
        let uniqueName = "\(UUID().uuidString)-\(baseName)"
        return FileManager.default.temporaryDirectory.appending(path: uniqueName)
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
