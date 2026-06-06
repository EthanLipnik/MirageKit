import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
//
//  MirageClientService+BootstrapRejectionMapping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//


package extension MirageClientService.ProtocolMismatchInfo.Reason {
    /// Maps host bootstrap rejection reasons into protocol-mismatch UI state.
    init(bootstrapRejectionReason reason: MirageWire.MirageSessionBootstrapRejectionReason?) {
        switch reason {
        case .protocolVersionMismatch:
            self = .protocolVersionMismatch
        case .hostBusy:
            self = .hostBusy
        case .hostUpdateInProgress:
            self = .hostUpdateInProgress
        case .rejected:
            self = .rejected
        case .unauthorized:
            self = .unauthorized
        case .takeoverRequiresTrustedRequester:
            self = .unauthorized
        case .none:
            self = .unknown
        }
    }
}

package extension MirageCore.MirageConnectionRejection.Reason {
    /// Maps host bootstrap rejection reasons into terminal connection-rejection state.
    init(
        bootstrapRejectionReason reason: MirageWire.MirageSessionBootstrapRejectionReason?,
        authorizationFailureReason: MirageWire.MirageSessionBootstrapAuthorizationFailureReason? = nil
    ) {
        if authorizationFailureReason == .remoteAccessDisabled {
            self = .remoteAccessDisabled
            return
        }

        switch reason {
        case .protocolVersionMismatch:
            self = .protocolVersionMismatch
        case .hostBusy:
            self = .hostBusy
        case .hostUpdateInProgress:
            self = .hostUpdateInProgress
        case .rejected:
            self = .rejected
        case .unauthorized:
            self = .unauthorized
        case .takeoverRequiresTrustedRequester:
            self = .takeoverRequiresTrustedRequester
        case .none:
            self = .unknown
        }
    }
}

package extension MirageDiagnostics.MirageHelloRejectionStepReason {
    /// Maps host bootstrap rejection reasons into diagnostics labels.
    init(bootstrapRejectionReason reason: MirageWire.MirageSessionBootstrapRejectionReason?) {
        switch reason {
        case .protocolVersionMismatch:
            self = .protocolVersionMismatch
        case .hostBusy:
            self = .hostBusy
        case .hostUpdateInProgress:
            self = .hostUpdateInProgress
        case .rejected:
            self = .rejected
        case .unauthorized,
             .takeoverRequiresTrustedRequester:
            self = .unauthorized
        case .none:
            self = .unknown
        }
    }
}
