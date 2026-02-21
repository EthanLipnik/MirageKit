//
//  MirageHostService+TransportExperiment.swift
//  MirageKit
//
//  Created by Codex on 2/21/26.
//
//  AWDL experiment transport recovery hooks.
//

import Foundation
import Network
import MirageKit

#if os(macOS)
@MainActor
extension MirageHostService {
    func handleVideoSendError(streamID: StreamID, error: NWError) async {
        guard awdlExperimentEnabled else { return }
        guard let context = streamsByID[streamID] else { return }
        let didTriggerRecovery = await context.handleTransportSendError(error)
        guard didTriggerRecovery else { return }

        sendErrorBursts &+= 1
        await sendTransportRefreshRequest(
            streamID: streamID,
            reason: "send-error-burst"
        )
        MirageLogger.host(
            "Transport recovery burst triggered for stream \(streamID) (count \(sendErrorBursts))"
        )
    }

    func sendTransportRefreshRequest(streamID: StreamID, reason: String) async {
        guard awdlExperimentEnabled else { return }
        guard let clientContext = clientContextForTransportRefresh(streamID: streamID) else {
            MirageLogger.host("Transport refresh request skipped (no client context for stream \(streamID))")
            return
        }

        let request = TransportRefreshRequestMessage(
            streamID: streamID,
            reason: reason
        )

        do {
            try await clientContext.send(.transportRefreshRequest, content: request)
            transportRefreshRequests &+= 1
            MirageLogger.host(
                "Sent transport refresh request for stream \(streamID) (\(reason), count \(transportRefreshRequests))"
            )
        } catch {
            MirageLogger.error(.host, "Failed to send transport refresh request for stream \(streamID): \(error)")
        }
    }

    private func clientContextForTransportRefresh(streamID: StreamID) -> ClientContext? {
        if desktopStreamID == streamID, let desktopStreamClientContext {
            return desktopStreamClientContext
        }
        if let session = activeStreams.first(where: { $0.id == streamID }),
           let context = clientsByID[session.client.id] {
            return context
        }
        return clientsByConnection.values.first
    }
}
#endif
