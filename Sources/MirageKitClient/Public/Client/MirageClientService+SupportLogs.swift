//
//  MirageClientService+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Client host-support-log request flow.
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

@MainActor
public extension MirageClientService {
    /// Requests a zipped support log archive from the connected host and stores it in a temporary file.
    func requestHostSupportLogArchive() async throws -> URL {
        guard case .connected = connectionState else {
            throw MirageCore.MirageError.protocolError("Not connected")
        }
        guard hostSupportLogArchiveContinuation == nil else {
            throw MirageCore.MirageError.protocolError("Host log export already in progress")
        }

        let requestID = UUID()
        let request = MirageWire.HostSupportLogArchiveRequestMessage(requestID: requestID)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                hostSupportLogArchiveRequestID = requestID
                hostSupportLogArchiveContinuation = continuation
                hostSupportLogArchiveTransferTask?.cancel()
                hostSupportLogArchiveTransferTask = nil
                hostSupportLogArchiveTimeoutTask?.cancel()
                hostSupportLogArchiveTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: self?.hostSupportLogArchiveTimeout ?? .seconds(45))
                    } catch {
                        return
                    }
                    guard let self,
                          hostSupportLogArchiveContinuation != nil else {
                        return
                    }
                    completeHostSupportLogArchiveRequest(
                        .failure(MirageCore.MirageError.protocolError("Timed out exporting host support logs"))
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
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.hostSupportLogArchiveRequestID == requestID else {
                    return
                }
                self?.completeHostSupportLogArchiveRequest(.failure(CancellationError()))
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
            throw MirageCore.MirageError.protocolError("Missing authenticated Loom transfer engine for host support logs")
        }
        let incomingTransfer = try await awaitIncomingTransfer(
            kind: "host-support-log-archive",
            requestID: requestID
        )
        MirageLogger.client(
            "Accepted host support log transfer offer requestID=\(rid) bytes=\(incomingTransfer.offer.byteLength)"
        )

        let sanitizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseName = sanitizedFileName.isEmpty
            ? "MirageHostSupportLogs.zip"
            : URL(fileURLWithPath: sanitizedFileName).lastPathComponent
        let destinationURL = FileManager.default.temporaryDirectory
            .appending(path: "\(UUID().uuidString)-\(baseName)")
        try await incomingTransfer.acceptFileTransfer(to: destinationURL)

        let terminalProgress = await MirageTransferProgress.terminalProgress(from: incomingTransfer.progressEvents)
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
            removeIncompleteHostSupportLogDownload(at: destinationURL, requestID: rid)
            throw CancellationError()
        default:
            MirageLogger.client(
                "Host support log transfer ended early requestID=\(rid) " +
                    "state=\(terminalProgress?.state.rawValue ?? "unknown")"
            )
            removeIncompleteHostSupportLogDownload(at: destinationURL, requestID: rid)
            throw MirageCore.MirageError.protocolError("Host support log transfer did not complete")
        }

        return destinationURL
    }

    private func removeIncompleteHostSupportLogDownload(at url: URL, requestID: String) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            MirageLogger.error(
                .client,
                error: error,
                message: "Failed to remove incomplete host support log download requestID=\(requestID): "
            )
        }
    }
}
