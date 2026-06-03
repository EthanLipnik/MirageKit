//
//  MirageClientService+BootstrapRejectionMapping.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import MirageKit

package extension MirageClientService.ProtocolMismatchInfo.Reason {
    /// Maps host bootstrap rejection reasons into protocol-mismatch UI state.
    init(bootstrapRejectionReason reason: MirageSessionBootstrapRejectionReason?) {
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

package extension MirageConnectionRejection.Reason {
    /// Maps host bootstrap rejection reasons into terminal connection-rejection state.
    init(
        bootstrapRejectionReason reason: MirageSessionBootstrapRejectionReason?,
        authorizationFailureReason: MirageSessionBootstrapAuthorizationFailureReason? = nil
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

package extension MirageHelloRejectionStepReason {
    /// Maps host bootstrap rejection reasons into diagnostics labels.
    init(bootstrapRejectionReason reason: MirageSessionBootstrapRejectionReason?) {
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
