//
//  MirageBootstrapControlCommandPlannerTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import Loom
import MirageCore
@testable import MirageConnectivity
import Testing

@Suite("Mirage Bootstrap Control Command Planner")
struct MirageBootstrapControlCommandPlannerTests {
    @Test("Unavailable command metadata returns no plan")
    func unavailableCommandMetadataReturnsNoPlan() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: false,
            supportsPreloginDaemon: true,
            endpoints: [
                LoomBootstrapEndpoint(host: "10.0.0.10", port: 22, source: .auto),
            ],
            sshPort: 22,
            controlPort: 9849,
            controlAuthSecret: "secret",
            controlCapabilities: [.commands],
            wakeOnLAN: nil
        )

        let plan = try MirageBootstrapControlCommandPlanner.commandPlanIfAvailable(
            metadata: metadata,
            fallbackEndpoint: nil,
            commandIdentifier: "test.command",
            commandBody: Data([0x01]),
            timeout: .seconds(5)
        )

        #expect(plan == nil)
    }

    @Test("Command plan trims secret and uses resolved endpoint priority")
    func commandPlanTrimsSecretAndUsesResolvedEndpointPriority() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            endpoints: [
                LoomBootstrapEndpoint(host: "beta.local", port: 22, source: .auto),
                LoomBootstrapEndpoint(host: "alpha.local", port: 22, source: .user),
                LoomBootstrapEndpoint(host: "ALPHA.local", port: 22, source: .lastSeen),
            ],
            sshPort: 22,
            controlPort: 9849,
            controlAuthSecret: "  shared-secret  ",
            controlCapabilities: [.commands],
            wakeOnLAN: nil
        )

        let optionalPlan = try MirageBootstrapControlCommandPlanner.commandPlanIfAvailable(
            metadata: metadata,
            fallbackEndpoint: nil,
            commandIdentifier: "test.command",
            commandBody: Data([0x02, 0x03]),
            timeout: .seconds(5)
        )
        let plan = try #require(optionalPlan)

        #expect(plan.endpoint == MirageBootstrapControlEndpoint(
            host: "alpha.local",
            port: 22,
            source: .user
        ))
        #expect(plan.controlPort == 9849)
        #expect(plan.controlAuthSecret == "shared-secret")
        #expect(plan.commandIdentifier == "test.command")
        #expect(plan.commandBody == Data([0x02, 0x03]))
        #expect(plan.timeout == .seconds(5))
    }

    @Test("Command plan falls back to remembered host when metadata has no endpoints")
    func commandPlanFallsBackToRememberedHostWhenMetadataHasNoEndpoints() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            endpoints: [],
            sshPort: 22,
            controlPort: 9849,
            controlAuthSecret: "secret",
            controlCapabilities: [.commands],
            wakeOnLAN: nil
        )
        let fallback = MirageBootstrapControlCommandPlanner.fallbackEndpoint(
            resolvedAddressDescriptions: ["192.168.1.44"],
            endpointHostDescription: "bonjour.local"
        )

        let optionalPlan = try MirageBootstrapControlCommandPlanner.commandPlanIfAvailable(
            metadata: metadata,
            fallbackEndpoint: fallback,
            commandIdentifier: "test.command",
            commandBody: nil,
            timeout: .seconds(5)
        )
        let plan = try #require(optionalPlan)

        #expect(plan.endpoint == MirageBootstrapControlEndpoint(
            host: "192.168.1.44",
            port: 22,
            source: .auto
        ))
    }

    @Test("Command plan reports missing usable endpoint")
    func commandPlanReportsMissingUsableEndpoint() throws {
        let metadata = LoomBootstrapMetadata(
            enabled: true,
            supportsPreloginDaemon: true,
            endpoints: [],
            sshPort: 22,
            controlPort: 9849,
            controlAuthSecret: "secret",
            controlCapabilities: [.commands],
            wakeOnLAN: nil
        )

        do {
            _ = try MirageBootstrapControlCommandPlanner.commandPlanIfAvailable(
                metadata: metadata,
                fallbackEndpoint: nil,
                commandIdentifier: "test.command",
                commandBody: nil,
                timeout: .seconds(5)
            )
            Issue.record("Expected missing endpoint to throw.")
        } catch let MirageCore.MirageError.protocolError(message) {
            #expect(message == "Host does not advertise a usable update control endpoint.")
        } catch {
            Issue.record("Unexpected error: \(error.localizedDescription)")
        }
    }
}
