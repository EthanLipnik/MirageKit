//
//  ControlReceiveLifecycleTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/10/26.
//

@testable import MirageKitClient
import Foundation
import Testing

@Suite("Control Receive Lifecycle")
struct ControlReceiveLifecycleTests {
    @Test("Receive callbacks only process the active control connection")
    func activeControlConnectionCheck() {
        let activeConnection = NSObject()
        #expect(
            MirageClientService.isCurrentControlReceiveSource(
                activeConnection: activeConnection,
                callbackConnection: activeConnection
            )
        )
    }

    @Test("Receive callbacks ignore stale control connections")
    func staleControlConnectionCheck() {
        #expect(
            !MirageClientService.isCurrentControlReceiveSource(
                activeConnection: NSObject(),
                callbackConnection: NSObject()
            )
        )
    }

    @Test("Receive callbacks stop after teardown clears the active connection")
    func nilActiveConnectionCheck() {
        #expect(
            !MirageClientService.isCurrentControlReceiveSource(
                activeConnection: nil,
                callbackConnection: NSObject()
            )
        )
    }
}
