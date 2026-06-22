//
//  MirageDiagnosticsContextLoomTests.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
@testable import MirageConnectivity
import Testing

@Suite("Mirage Diagnostics Context Loom Adapter")
struct MirageDiagnosticsContextLoomTests {
    @Test("Diagnostics context registry projects Mirage values into Loom snapshots")
    func diagnosticsContextRegistryProjectsMirageValuesIntoLoomSnapshots() async {
        let token = await MirageDiagnosticsContextRegistry.registerContextProvider {
            [
                "mirage.test.string": .string("value"),
                "mirage.test.bool": .bool(true),
                "mirage.test.int": .int(7),
                "mirage.test.double": .double(1.5),
                "mirage.test.array": .array([.int(1), .string("two")]),
                "mirage.test.dictionary": .dictionary(["nested": .bool(false)]),
                "mirage.test.null": .null,
            ]
        }

        let snapshot = await LoomDiagnostics.snapshotContext()
        await MirageDiagnosticsContextRegistry.unregisterContextProvider(token)

        #expect(snapshot["mirage.test.string"] == .string("value"))
        #expect(snapshot["mirage.test.bool"] == .bool(true))
        #expect(snapshot["mirage.test.int"] == .int(7))
        #expect(snapshot["mirage.test.double"] == .double(1.5))
        #expect(snapshot["mirage.test.array"] == .array([.int(1), .string("two")]))
        #expect(snapshot["mirage.test.dictionary"] == .dictionary(["nested": .bool(false)]))
        #expect(snapshot["mirage.test.null"] == .null)
    }
}
