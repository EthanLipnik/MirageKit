//
//  MirageClientControlSessionAttemptSummary.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Point-in-time summary of one client control-session connection attempt.
public struct MirageClientControlSessionAttemptSummary: Sendable, Equatable {
    public let observedAt: Date
    public let phase: String
    public let hostName: String
    public let transport: String
    public let endpoint: String
    public let candidateKind: String
    public let routeTier: String
    public let endpointSource: String
    public let requiredInterface: String
    public let proximity: String
    public let outcome: String

    public init(
        observedAt: Date,
        phase: String,
        hostName: String,
        transport: String,
        endpoint: String,
        candidateKind: String,
        routeTier: String,
        endpointSource: String,
        requiredInterface: String,
        proximity: String,
        outcome: String
    ) {
        self.observedAt = observedAt
        self.phase = phase
        self.hostName = hostName
        self.transport = transport
        self.endpoint = endpoint
        self.candidateKind = candidateKind
        self.routeTier = routeTier
        self.endpointSource = endpointSource
        self.requiredInterface = requiredInterface
        self.proximity = proximity
        self.outcome = outcome
    }

    public var supportSummaryLine: String {
        "\(observedAt.ISO8601Format()) phase=\(phase) host=\(hostName) " +
            "transport=\(transport) candidate=\(candidateKind) endpoint=\(endpoint) " +
            "route=\(routeTier) source=\(endpointSource) interface=\(requiredInterface) " +
            "proximity=\(proximity) outcome=\(outcome)"
    }
}
