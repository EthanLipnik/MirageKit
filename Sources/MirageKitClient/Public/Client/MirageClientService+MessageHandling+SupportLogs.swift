//
//  MirageClientService+MessageHandling+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Host support log archive response handling.
//

import Foundation
import MirageKit

@MainActor
extension MirageClientService {
    func handleHostSupportLogArchive(_ message: ControlMessage) {
        do {
            let archive = try message.decode(HostSupportLogArchiveMessage.self)

            if let errorMessage = archive.errorMessage,
               !errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError(errorMessage))
                )
                return
            }

            guard let archiveData = archive.archiveData,
                  !archiveData.isEmpty else {
                completeHostSupportLogArchiveRequest(
                    .failure(MirageError.protocolError("Host returned an empty support log archive"))
                )
                return
            }

            let fileName = archive.fileName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedFileName = (fileName?.isEmpty == false ? fileName : nil) ?? "MirageHostSupportLogs.zip"
            completeHostSupportLogArchiveRequest(
                .success(MirageHostSupportLogArchive(fileName: resolvedFileName, archiveData: archiveData))
            )
        } catch {
            completeHostSupportLogArchiveRequest(.failure(error))
            MirageLogger.error(.client, error: error, message: "Failed to decode host support log archive: ")
        }
    }
}
