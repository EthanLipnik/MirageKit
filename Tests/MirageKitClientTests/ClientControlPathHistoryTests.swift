//
//  ClientControlPathHistoryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

@testable import MirageKitClient
import MirageKit
import Foundation
import Testing

@Suite("Client Control Path History")
struct ClientControlPathHistoryTests {
    @Test("Duplicate path snapshots do not create duplicate history entries")
    func duplicateSnapshotsAreDeduplicated() {
        let observedAt = Date(timeIntervalSince1970: 1_775_155_000)
        let status = makeStatus(
            kind: .wired,
            interfaceNames: ["en12"],
            usesWired: true
        )

        let initial = MirageClientService.appendedControlPathHistory(
            [],
            status: status,
            observedAt: observedAt,
            maxCount: 8
        )
        let deduplicated = MirageClientService.appendedControlPathHistory(
            initial,
            status: status,
            observedAt: observedAt.addingTimeInterval(5),
            maxCount: 8
        )

        #expect(initial.count == 1)
        #expect(deduplicated.count == 1)
        #expect(deduplicated.first?.observedAt == observedAt)
    }

    @Test("Path history keeps the newest entries when trimmed")
    func pathHistoryKeepsNewestEntriesWhenTrimmed() {
        var history: [MirageClientNetworkPathHistoryEntry] = []

        for index in 0..<4 {
            let kind: MirageNetworkPathKind = index.isMultiple(of: 2) ? .wifi : .wired
            let interface = index.isMultiple(of: 2) ? "en0" : "en12"
            history = MirageClientService.appendedControlPathHistory(
                history,
                status: makeStatus(
                    kind: kind,
                    interfaceNames: [interface],
                    usesWired: kind == .wired,
                    usesOther: kind == .awdl
                ),
                observedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                maxCount: 3
            )
        }

        #expect(history.count == 3)
        #expect(history.map(\.status.interfaceSummary) == ["en12", "en0", "en12"])
    }

    private func makeStatus(
        kind: MirageNetworkPathKind,
        interfaceNames: [String],
        usesWired: Bool = false,
        usesOther: Bool = false
    ) -> MirageClientNetworkPathStatus {
        MirageClientNetworkPathStatus(
            kind: kind,
            status: "satisfied",
            interfaceNames: interfaceNames,
            isExpensive: false,
            isConstrained: false,
            supportsIPv4: true,
            supportsIPv6: true,
            usesWiFi: kind == .wifi,
            usesWired: usesWired,
            usesCellular: kind == .cellular,
            usesLoopback: kind == .loopback,
            usesOther: usesOther
        )
    }
}
