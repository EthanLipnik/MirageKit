//
//  MirageNetworkPathClassifierTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/21/26.
//
//  AWDL transport path classification behavior coverage.
//

@testable import MirageKit
import Testing

@Suite("Network Path Classifier")
struct MirageNetworkPathClassifierTests {
    @Test("AWDL classification prefers awdl interface signatures over generic other")
    func classifyAwdlPath() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0", "awdl0"],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: true,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .awdl)
        #expect(snapshot.isReady)
        #expect(snapshot.signature.localizedStandardContains("kind=awdl"))
    }

    @Test("Wi-Fi classification remains stable when AWDL interface is absent")
    func classifyWiFiPath() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: ["en0"],
            usesWiFi: true,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "satisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true
        )

        #expect(snapshot.kind == .wifi)
    }

    @Test("Unknown classification applies when no interface hints are present")
    func classifyUnknownPath() {
        let snapshot = MirageNetworkPathClassifier.classify(
            interfaceNames: [],
            usesWiFi: false,
            usesWired: false,
            usesCellular: false,
            usesLoopback: false,
            usesOther: false,
            status: "unsatisfied",
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: false,
            supportsIPv6: false
        )

        #expect(snapshot.kind == .unknown)
        #expect(!snapshot.isReady)
    }
}
