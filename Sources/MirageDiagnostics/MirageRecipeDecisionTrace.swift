//
//  MirageRecipeDecisionTrace.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Diagnostics trace explaining how a stream recipe was resolved.
public struct MirageRecipeDecisionTrace: Sendable, Codable, Equatable {
    /// Ordered resolution decisions.
    public var decisions: [MirageRecipeDecision]

    /// Creates a decision trace.
    public init(decisions: [MirageRecipeDecision] = []) {
        self.decisions = decisions
    }

    /// Returns a copy with one appended decision.
    public func appending(_ decision: MirageRecipeDecision) -> MirageRecipeDecisionTrace {
        var copy = self
        copy.decisions.append(decision)
        return copy
    }
}

/// Single recipe-resolution decision for diagnostics.
public struct MirageRecipeDecision: Sendable, Codable, Equatable {
    /// Stable key for the decision.
    public let key: String

    /// Selected value.
    public let value: String

    /// Reason the value was selected.
    public let reason: String

    /// Creates a recipe-resolution decision.
    public init(key: String, value: String, reason: String) {
        self.key = key
        self.value = value
        self.reason = reason
    }
}
