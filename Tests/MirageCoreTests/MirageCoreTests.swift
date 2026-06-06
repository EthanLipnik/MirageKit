//
//  MirageCoreTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageCore
import Testing

@Suite("MirageCore")
struct MirageCoreTests {
    @Test("Core identifiers keep stable wire widths")
    func coreIdentifiersKeepStableWireWidths() {
        #expect(MemoryLayout<WindowID>.size == MemoryLayout<UInt32>.size)
        #expect(MemoryLayout<StreamID>.size == MemoryLayout<UInt16>.size)
        #expect(StreamSessionID.self == UUID.self)
        #expect(StreamPresentationID.self == UUID.self)
        #expect(MirageNetworkDefaults.serviceType == "_mirage._tcp")
        #expect(MirageNetworkDefaults.directTCPPort == 9853)
        #expect(MirageNetworkDefaults.directUDPPort == 9854)
        #expect(MirageNetworkDefaults.directQUICPort == 9855)
        #expect(MirageNetworkDefaults.overlayProbePort == 9852)
    }

    @Test("Network path kind keeps stable wire names")
    func networkPathKindKeepsStableWireNames() throws {
        let knownKinds: [MirageCore.MirageNetworkPathKind] = [
            .awdl,
            .wifi,
            .wired,
            .cellular,
            .vpn,
            .loopback,
            .other,
            .unknown,
        ]
        #expect(knownKinds.map(\.rawValue) == [
            "awdl",
            "wifi",
            "wired",
            "cellular",
            "vpn",
            "loopback",
            "other",
            "unknown",
        ])

        let encoded = try JSONEncoder().encode(MirageCore.MirageNetworkPathKind.awdl)
        let decoded = try JSONDecoder().decode(MirageCore.MirageNetworkPathKind.self, from: encoded)

        #expect(String(data: encoded, encoding: .utf8) == "\"awdl\"")
        #expect(decoded == .awdl)
    }

    @Test("Connection rejections keep terminal and message behavior")
    func connectionRejectionsKeepTerminalAndMessageBehavior() {
        let rejection = MirageCore.MirageConnectionRejection(
            reason: .protocolVersionMismatch,
            hostName: "Studio Mac",
            hostProtocolVersion: 9,
            clientProtocolVersion: 8
        )

        #expect(rejection.isTerminal)
        #expect(rejection.userFacingMessage == "Studio Mac: Mirage versions are incompatible. Host protocol 9, client protocol 8.")
        #expect(MirageCore.MirageError.connectionRejected(rejection).errorDescription == rejection.userFacingMessage)
    }

    @Test("Runtime condition diagnostics domain preserves existing grouping")
    func runtimeConditionDiagnosticsDomainPreservesExistingGrouping() {
        #expect(MirageCore.MirageRuntimeConditionError.sessionLocked < .waitingForHostApproval)
        #expect(MirageCore.MirageRuntimeConditionError.sessionLocked.message == "Session is locked")
        #expect(MirageCore.MirageRuntimeConditionError.diagnosticsDomain == "MirageKit.MirageRuntimeConditionError")
    }
}
