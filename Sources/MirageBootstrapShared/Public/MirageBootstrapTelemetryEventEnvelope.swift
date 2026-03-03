//
//  MirageBootstrapTelemetryEventEnvelope.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Shared queue envelope for daemon telemetry handoff to host app reporting.
//

import Foundation

public enum MirageBootstrapTelemetryEventKind: String, Codable, Sendable {
    case analytics
    case diagnostic
}

public enum MirageBootstrapTelemetryEventSource: String, Codable, Sendable {
    case daemon
}

public struct MirageBootstrapTelemetryEventEnvelope: Codable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let kind: MirageBootstrapTelemetryEventKind
    public let eventName: String
    public let message: String?
    public let metadata: [String: String]
    public let source: MirageBootstrapTelemetryEventSource

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        kind: MirageBootstrapTelemetryEventKind,
        eventName: String,
        message: String? = nil,
        metadata: [String: String] = [:],
        source: MirageBootstrapTelemetryEventSource = .daemon
    ) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.eventName = eventName
        self.message = message
        self.metadata = metadata
        self.source = source
    }
}

public enum MirageBootstrapTelemetryQueueConstants {
    public static let fileName = "daemon-telemetry-queue.jsonl"
    public static let maxFileBytes = 1_048_576
    public static let maxEntries = 1_024
}
