//
//  HostConnectionErrorClassificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

#if os(macOS)
@testable import MirageKitHost
import Network
import Testing

@Suite("Host Connection Error Classification")
struct HostConnectionErrorClassificationTests {
    @MainActor
    @Test("NWError POSIX disconnects are treated as fatal connection errors")
    func nwPosixDisconnectIsFatal() {
        let service = MirageHostService()

        #expect(service.isFatalConnectionError(NWError.posix(.ENOTCONN)))
        #expect(service.isFatalConnectionError(NWError.posix(.ECONNRESET)))
    }
}
#endif
