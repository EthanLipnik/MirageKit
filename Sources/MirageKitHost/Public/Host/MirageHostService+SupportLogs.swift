//
//  MirageHostService+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Host support log archive request handling.
//

import Foundation
import MirageKit

#if os(macOS)
import Network

@MainActor
extension MirageHostService {
    func handleHostSupportLogArchiveRequest(
        _ message: ControlMessage,
        from _: MirageConnectedClient,
        connection: NWConnection
    ) async {
        guard let clientContext = clientsByConnection[ObjectIdentifier(connection)] else {
            return
        }

        do {
            _ = try message.decode(HostSupportLogArchiveRequestMessage.self)

            guard let hostSupportLogArchiveProvider else {
                let response = HostSupportLogArchiveMessage(
                    errorMessage: "Host log export is unavailable."
                )
                try await clientContext.send(.hostSupportLogArchive, content: response)
                MirageLogger.host("Host support log archive request rejected: provider unavailable")
                return
            }

            let archive = try await hostSupportLogArchiveProvider()
            let response = HostSupportLogArchiveMessage(
                fileName: archive.fileName,
                archiveData: archive.archiveData
            )
            try await clientContext.send(.hostSupportLogArchive, content: response)

            MirageLogger.host(
                "Sent host support log archive bytes=\(archive.archiveData.count) filename=\(archive.fileName)"
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to handle host support log archive request: ")
            if let clientContext = clientsByConnection[ObjectIdentifier(connection)] {
                let response = HostSupportLogArchiveMessage(
                    errorMessage: "Failed to export host logs."
                )
                try? await clientContext.send(.hostSupportLogArchive, content: response)
            }
        }
    }
}
#endif
