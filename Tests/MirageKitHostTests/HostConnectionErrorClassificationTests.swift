//
//  HostConnectionErrorClassificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

#if os(macOS)
@testable import MirageKitHost
import Loom
import MirageKit
import Network
import Testing

@Suite("Host Connection Error Classification")
struct HostConnectionErrorClassificationTests {
    @MainActor
    @Test("NWError POSIX disconnects are treated as fatal connection errors")
    func nwPosixDisconnectIsFatal() {
        let service = MirageHostService()

        #expect(service.isFatalConnectionError(NWError.posix(.ECANCELED)))
        #expect(service.isFatalConnectionError(NWError.posix(.ENOTCONN)))
        #expect(service.isFatalConnectionError(NWError.posix(.ECONNRESET)))
    }

    @MainActor
    @Test("Mirage connection-failed wrapper is fatal for closed bootstrap sessions")
    func closedBootstrapSessionWrappedAsConnectionFailureIsFatal() {
        let service = MirageHostService()
        let error = MirageError.connectionFailed(
            LoomConnectionFailure(
                reason: .closed,
                detail: "Authenticated Loom session closed before Mirage control stream opened"
            )
        )

        #expect(service.isFatalConnectionError(error))
    }

    @MainActor
    @Test("Bootstrap control stream closure before open is treated as expected bootstrap closure")
    func bootstrapControlStreamClosureBeforeOpenIsExpected() {
        let service = MirageHostService()
        let error = MirageError.protocolError(
            "Authenticated Loom session closed before Mirage control stream opened"
        )

        #expect(service.isExpectedBootstrapConnectionClosure(error))
    }

    @MainActor
    @Test("Bootstrap control stream closure before request is treated as expected bootstrap closure")
    func bootstrapControlStreamClosureBeforeRequestIsExpected() {
        let service = MirageHostService()
        let error = MirageError.protocolError(
            "Control stream closed before session bootstrap request"
        )

        #expect(service.isExpectedBootstrapConnectionClosure(error))
    }
}
#endif
