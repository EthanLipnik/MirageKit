//
//  MirageHostService+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Host Mirage-app control request handling.
//

import Foundation
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleHostApplicationRestartRequest(
        _ message: ControlMessage,
        from clientContext: ClientContext
    ) async {
        do {
            _ = try message.decode(HostApplicationRestartRequestMessage.self)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to decode host application restart request: ")
            return
        }

        guard let restartHandler = hostApplicationRestartHandler else {
            let response = HostApplicationRestartResultMessage(
                accepted: false,
                message: "Host app restart is unavailable."
            )
            do {
                try await clientContext.send(.hostApplicationRestartResult, content: response)
            } catch {
                await handleControlChannelSendFailure(
                    client: clientContext.client,
                    error: error,
                    operation: "Host application restart result",
                    sessionID: clientContext.sessionID
                )
            }
            MirageLogger.host("Host application restart request rejected: handler unavailable")
            return
        }

        if let authorizer = hostApplicationRestartAuthorizer {
            let isAuthorized = await authorizer(clientContext.client)
            guard isAuthorized else {
                let response = HostApplicationRestartResultMessage(
                    accepted: false,
                    message: "Local authorization is required to restart Mirage Host."
                )
                do {
                    try await clientContext.send(.hostApplicationRestartResult, content: response)
                } catch {
                    await handleControlChannelSendFailure(
                        client: clientContext.client,
                        error: error,
                        operation: "Host application restart authorization result",
                        sessionID: clientContext.sessionID
                    )
                }
                MirageLogger.host("Denied host application restart request from \(clientContext.client.name)")
                return
            }
        }

        let response = HostApplicationRestartResultMessage(
            accepted: true,
            message: "Restarting Mirage Host."
        )
        do {
            try await clientContext.send(.hostApplicationRestartResult, content: response)
            MirageLogger.host("Accepted host application restart request from \(clientContext.client.name)")
        } catch {
            await handleControlChannelSendFailure(
                client: clientContext.client,
                error: error,
                operation: "Host application restart result",
                sessionID: clientContext.sessionID
            )
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            restartHandler()
        }
    }
}
#endif
