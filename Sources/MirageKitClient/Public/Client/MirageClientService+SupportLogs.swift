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

@MainActor
public extension MirageClientService {
    /// Requests a zipped support log archive from the connected host and stores it in a temporary file.
    func requestHostSupportLogArchive() async throws -> URL {
        guard case .connected = connectionState else {
            throw MirageError.protocolError("Not connected")
        }
        guard hostSupportLogArchiveContinuation == nil else {
            throw MirageError.protocolError("Host log export already in progress")
        }

        let requestID = UUID()
        let request = HostSupportLogArchiveRequestMessage(requestID: requestID)

        return try await withCheckedThrowingContinuation { continuation in
            hostSupportLogArchiveRequestID = requestID
            hostSupportLogArchiveContinuation = continuation
            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = nil
            hostSupportLogArchiveTimeoutTask?.cancel()
            hostSupportLogArchiveTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.hostSupportLogArchiveTimeout ?? .seconds(45))
                guard let self,
                      self.hostSupportLogArchiveContinuation != nil else {
                    return
                }
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError("Timed out exporting host support logs"))
                )
            }
            Task { @MainActor [weak self] in
                do {
                    try await self?.sendControlMessage(.hostSupportLogArchiveRequest, content: request)
                } catch {
                    self?.completeHostSupportLogArchiveRequest(.failure(error))
                }
            }
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
        fileName: String
    ) async throws -> URL {
        let rid = requestID.uuidString.lowercased()
        MirageLogger.client("Downloading host support log archive requestID=\(rid) using active Loom session")

        guard transferEngine != nil else {
            throw MirageError.protocolError("Missing authenticated Loom transfer engine for host support logs")
        }
        let incomingTransfer = try await awaitIncomingTransfer(
            kind: "host-support-log-archive",
            requestID: requestID
        )
        MirageLogger.client(
            "Accepted host support log transfer offer requestID=\(rid) bytes=\(incomingTransfer.offer.byteLength)"
        )

        let destinationURL = uniqueSupportLogDestinationURL(fileName: fileName)
        let sink = try LoomFileTransferSink(url: destinationURL)
        try await incomingTransfer.accept(using: sink)

        let terminalProgress = await terminalProgress(from: incomingTransfer.progressEvents)
        switch terminalProgress?.state {
        case .completed:
            MirageLogger.client(
                "Completed host support log download requestID=\(rid) file=\(destinationURL.lastPathComponent)"
            )
        case .cancelled, .declined:
            MirageLogger.client(
                "Host support log transfer ended early requestID=\(rid) " +
                    "state=\(terminalProgress?.state.rawValue ?? "unknown")"
            )
            try? FileManager.default.removeItem(at: destinationURL)
            throw CancellationError()
        default:
            MirageLogger.client(
                "Host support log transfer ended early requestID=\(rid) " +
                    "state=\(terminalProgress?.state.rawValue ?? "unknown")"
            )
            try? FileManager.default.removeItem(at: destinationURL)
            throw MirageError.protocolError("Host support log transfer did not complete")
        }

        return destinationURL
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
