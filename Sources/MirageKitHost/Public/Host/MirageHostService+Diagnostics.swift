//
//  MirageHostService+Diagnostics.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import Loom

#if os(macOS)
@MainActor
extension MirageHostService {
    /// Registers a Loom diagnostics provider for the current host state.
    func registerDiagnosticsContextProvider() {
        Task { [weak self] in
            guard let self else { return }
            diagnosticsContextProviderToken = await LoomDiagnostics.registerContextProvider { [weak self] in
                guard let self else { return [:] }
                return await MainActor.run { self.diagnosticsContextSnapshot }
            }
        }
    }

    /// Point-in-time host diagnostics emitted with Loom reports.
    private var diagnosticsContextSnapshot: LoomDiagnosticsContext {
        [
            "host.state": .string(Self.diagnosticsHostStateName(state)),
            "host.sessionState": .string(String(describing: sessionState)),

            "host.remoteTransportEnabled": .bool(remoteTransportEnabled),
            "host.lightsOutEnabled": .bool(lightsOutEnabled),
            "host.lightsOutDisabledByEnvironment": .bool(lightsOutDisabledByEnvironment),
            "host.lockHostWhenStreamingStops": .bool(lockHostWhenStreamingStops),
            "host.connectedClientsCount": .int(connectedClients.count),
            "host.activeStreamsCount": .int(activeStreams.count),
            "host.availableWindowsCount": .int(availableWindows.count),
            "host.desktopStreamActive": .bool(desktopStreamID != nil),

            "host.desktopResizeInFlight": .bool(activeDesktopResizeRequest != nil),
            "host.desktopSharedDisplayTransitionInFlight": .bool(desktopSharedDisplayTransitionInFlight),
            "host.windowVirtualDisplayCount": .int(windowVirtualDisplayStateByWindowID.count),
        ]
    }

    /// Stable diagnostics label for host advertising state.
    private static func diagnosticsHostStateName(_ state: HostState) -> String {
        switch state {
        case .idle:
            "idle"
        case .starting:
            "starting"
        case .advertising:
            "advertising"
        case .error:
            "error"
        }
    }
}
#endif
