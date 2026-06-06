//
//  MirageInstrumentationModels.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

/// Diagnostics reason attached to a rejected client hello step.
package enum MirageHelloRejectionStepReason: String, Equatable {
    case protocolVersionMismatch = "protocol_version_mismatch"
    case hostBusy = "host_busy"
    case hostUpdateInProgress = "host_update_in_progress"
    case rejected
    case unauthorized
    case unknown
}

/// Low-cardinality Mirage lifecycle step used by instrumentation.
package enum MirageStepEvent: Equatable {
    case clientHelloSent
    case clientConnectionRequested
    case clientConnectionFailed
    case clientConnectionDisconnected
    case clientHelloAccepted
    case clientHelloRejected(MirageHelloRejectionStepReason)
    case hostClientDisconnected

    package var name: String {
        switch self {
        case .clientHelloSent:
            "mirage.client.hello.sent"
        case .clientConnectionRequested:
            "mirage.client.connection.requested"
        case .clientConnectionFailed:
            "mirage.client.connection.failed"
        case .clientConnectionDisconnected:
            "mirage.client.connection.disconnected"
        case .clientHelloAccepted:
            "mirage.client.hello.accepted"
        case let .clientHelloRejected(reason):
            "mirage.client.hello.rejected.\(reason.rawValue)"
        case .hostClientDisconnected:
            "mirage.host.client.disconnected"
        }
    }
}
