//
//  MirageClientService+SupportLogs.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/13/26.
//
//  Client host-support-log request flow.
//

import Foundation
import MirageKit

@MainActor
public extension MirageClientService {
    /// Requests a zipped support log archive from the connected host.
    /// - Returns: Host-provided archive payload and suggested filename.
    func requestHostSupportLogArchive() async throws -> MirageHostSupportLogArchive {
        guard case .connected = connectionState, let connection else {
            throw MirageError.protocolError("Not connected")
        }
        guard hostSupportLogArchiveContinuation == nil else {
            throw MirageError.protocolError("Host log export already in progress")
        }

        let request = HostSupportLogArchiveRequestMessage()
        let message = try ControlMessage(type: .hostSupportLogArchiveRequest, content: request)
        let data = message.serialize()

        return try await withCheckedThrowingContinuation { continuation in
            hostSupportLogArchiveContinuation = continuation
            hostSupportLogArchiveTimeoutTask?.cancel()
            hostSupportLogArchiveTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: self?.hostSupportLogArchiveTimeout ?? .seconds(15))
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
    func completeHostSupportLogArchiveRequest(_ result: Result<MirageHostSupportLogArchive, Error>) {
        guard let continuation = hostSupportLogArchiveContinuation else { return }
        hostSupportLogArchiveContinuation = nil
        hostSupportLogArchiveTimeoutTask?.cancel()
        hostSupportLogArchiveTimeoutTask = nil
        continuation.resume(with: result)
    }
}
