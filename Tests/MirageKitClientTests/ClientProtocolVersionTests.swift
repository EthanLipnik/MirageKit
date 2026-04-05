//
//  ClientProtocolVersionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/4/26.
//

@testable import MirageKit
@testable import MirageKitClient
import Testing

@Suite("Client Protocol Version")
struct ClientProtocolVersionTests {
    @MainActor
    @Test("Client hello protocol version matches Mirage wire protocol")
    func clientHelloProtocolVersionMatchesMirageProtocol() {
        #expect(MirageClientService.clientProtocolVersion == Int(MirageKit.protocolVersion))
        #expect(Int(MirageKit.protocolVersion) == Int(mirageProtocolVersion))
    }
}
