//
//  MirageHostService+HostApplicationControl.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/12/26.
//
//  Host Mirage-app control request handling.
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
#if os(macOS)
@MainActor
extension MirageHostService {
    func handleHostApplicationRestartRequest(
        from clientContext: ClientContext
    ) async {
        guard let restartHandler = hostApplicationRestartHandler else {
            let response = MirageWire.HostApplicationRestartResultMessage(
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
                let response = MirageWire.HostApplicationRestartResultMessage(
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

        let response = MirageWire.HostApplicationRestartResultMessage(
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
            do {
                try await Task.sleep(for: .milliseconds(250))
            } catch {
                return
            }
            restartHandler()
        }
    }
}
#endif
