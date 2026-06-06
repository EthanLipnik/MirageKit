//
//  MirageRecipeDecisionTraceDiagnosticsTests.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageDiagnostics
import Testing

@Suite("Mirage Recipe Decision Trace Diagnostics")
struct MirageRecipeDecisionTraceDiagnosticsTests {
    @Test("Recipe decision traces append without mutating originals")
    func recipeDecisionTracesAppendWithoutMutatingOriginals() {
        let original = MirageDiagnostics.MirageRecipeDecisionTrace()
        let appended = original.appending(
            MirageDiagnostics.MirageRecipeDecision(
                key: "mediaStrategy",
                value: "fullFrameHEVC",
                reason: "Current desktop streaming behavior"
            )
        )

        #expect(original.decisions.isEmpty)
        #expect(appended.decisions.count == 1)
        #expect(appended.decisions[0].key == "mediaStrategy")
    }

    @Test("Recipe decision traces preserve stable Codable fields")
    func recipeDecisionTracesPreserveStableCodableFields() throws {
        let trace = MirageDiagnostics.MirageRecipeDecisionTrace(decisions: [
            MirageDiagnostics.MirageRecipeDecision(
                key: "presentationPolicy",
                value: "desktop",
                reason: "Requested desktop stream"
            ),
            MirageDiagnostics.MirageRecipeDecision(
                key: "connectivity",
                value: "interactiveMedia",
                reason: "Default stream policy"
            ),
        ])

        let decoded = try JSONDecoder().decode(
            MirageDiagnostics.MirageRecipeDecisionTrace.self,
            from: try JSONEncoder().encode(trace)
        )

        #expect(decoded == trace)
        #expect(decoded.decisions.map(\.key) == ["presentationPolicy", "connectivity"])
    }
}
