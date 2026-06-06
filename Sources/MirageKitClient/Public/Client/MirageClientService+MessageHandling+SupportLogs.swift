//
//  MirageClientService+MessageHandling+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Host support log transfer bootstrap response handling.
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
extension MirageClientService {
    func handleHostSupportLogArchive(_ message: MirageWire.ControlMessage) {
        do {
            let response = try message.decode(MirageWire.HostSupportLogArchiveMessage.self)
            guard let requestID = response.requestID,
                  requestID == hostSupportLogArchiveRequestID else {
                MirageLogger.client("Ignoring stale host support log response")
                return
            }

            if let errorMessage = response.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageCore.MirageError.protocolError(errorMessage))
                )
                return
            }

            guard let fileName = response.fileName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !fileName.isEmpty else {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageCore.MirageError.protocolError("Host returned incomplete support log transfer metadata"))
                )
                return
            }

            hostSupportLogArchiveTransferTask?.cancel()
            hostSupportLogArchiveTransferTask = Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let archiveURL = try await downloadHostSupportLogArchive(
                        requestID: requestID,
                        fileName: fileName
                    )
                    completeHostSupportLogArchiveRequest(.success(archiveURL))
                } catch {
                    completeHostSupportLogArchiveRequest(.failure(error))
                    if error is CancellationError {
                        MirageLogger.client("Host support log transfer ended after disconnect")
                    } else if case .connected = connectionState {
                        MirageLogger.error(.client, error: error, message: "Failed to download host support logs: ")
                    } else {
                        MirageLogger.client("Host support log transfer ended after disconnect")
                    }
                }
            }
        } catch {
            completeHostSupportLogArchiveRequest(.failure(error))
            MirageLogger.error(.client, error: error, message: "Failed to decode host support log bootstrap: ")
        }
    }
}
