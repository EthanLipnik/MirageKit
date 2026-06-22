//
//  HostConnectionErrorClassificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

#if os(macOS)
@testable import MirageKitHost
import MirageKit
import Network
import Testing
import MirageCore

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
    @Test("Bootstrap control stream closure before open is treated as expected bootstrap closure")
    func bootstrapControlStreamClosureBeforeOpenIsExpected() {
        let service = MirageHostService()
        let error = MirageCore.MirageError.protocolError(
            "Authenticated Loom session closed before Mirage control stream opened"
        )

        #expect(service.isExpectedBootstrapConnectionClosure(error))
    }

    @MainActor
    @Test("Bootstrap control stream closure before request is treated as expected bootstrap closure")
    func bootstrapControlStreamClosureBeforeRequestIsExpected() {
        let service = MirageHostService()
        let error = MirageCore.MirageError.protocolError(
            "Control stream closed before session bootstrap request"
        )

        #expect(service.isExpectedBootstrapConnectionClosure(error))
    }

    @MainActor
    @Test("Mirage connection-failed wrapper is treated as fatal")
    func mirageConnectionFailedWrapperIsFatal() {
        let service = MirageHostService()
        let error = MirageCore.MirageError.connectionFailed(NWError.posix(.ECONNRESET))

        #expect(service.isFatalConnectionError(error))
    }
}
#endif
