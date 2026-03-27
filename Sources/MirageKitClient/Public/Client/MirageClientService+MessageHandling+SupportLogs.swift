//
//  MirageClientService+MessageHandling+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Host support log transfer bootstrap response handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    private func shouldSuppressHostSupportLogFailure(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }

        if case .connected = connectionState {
            return false
        }

        return true
    }

    func handleHostSupportLogArchive(_ message: ControlMessage) {
        do {
            let response = try message.decode(HostSupportLogArchiveMessage.self)
            guard let requestID = response.requestID,
                  requestID == hostSupportLogArchiveRequestID else {
                MirageLogger.client("Ignoring stale host support log response")
                return
            }

            if let errorMessage = response.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError(errorMessage))
                )
                return
            }

            guard let fileName = response.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fileName.isEmpty,
                  let transportKind = response.transportKind,
                  let port = response.port else {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError("Host returned incomplete Loom transfer bootstrap data"))
                )
                return
            }

            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let archiveURL = try await downloadHostSupportLogArchive(
                        requestID: requestID,
                        fileName: fileName,
                        transportKind: transportKind,
                        port: port
                    )
                    completeHostSupportLogArchiveRequest(.success(archiveURL))
                } catch {
                    completeHostSupportLogArchiveRequest(.failure(error))
                    if shouldSuppressHostSupportLogFailure(error) {
                        MirageLogger.client("Host support log transfer ended after disconnect")
                    } else {
                        MirageLogger.error(.client, error: error, message: "Failed to download host support logs: ")
                    }
                }
            }
        } catch {
            completeHostSupportLogArchiveRequest(.failure(error))
            MirageLogger.error(.client, error: error, message: "Failed to decode host support log bootstrap: ")
        }
    }
}
