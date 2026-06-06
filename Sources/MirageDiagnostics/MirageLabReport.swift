//
//  MirageLabReport.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Status for a completed Lab run.
@_spi(Labs)
public enum MirageLabRunStatus: String, Codable, Sendable {
    case completed
    case failed
    case cancelled
    case invalid
}

/// Numeric measurement emitted by a Lab report.
@_spi(Labs)
public struct MirageLabMetric: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let unit: String
    public let value: Double
    public let dimensions: [String: String]

    public init(
        id: String,
        title: String,
        unit: String,
        value: Double,
        dimensions: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.unit = unit
        self.value = value
        self.dimensions = dimensions
    }
}

/// File or bundle produced by a Lab run.
@_spi(Labs)
public struct MirageLabArtifact: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public let kind: String
    public let url: URL

    public init(
        id: String,
        title: String,
        kind: String,
        url: URL
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.url = url
    }
}

/// Schema constants for generic Lab reports.
@_spi(Labs)
public enum MirageLabReportSchema {
    public static let currentVersion = 1
}

/// Versioned report emitted by any Lab runner.
@_spi(Labs)
public struct MirageLabReport: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let schemaVersion: Int
    public let labID: String
    public let labTitle: String
    public let category: MirageLabCategory
    public let configuration: MirageLabConfiguration
    public let measuredAt: Date
    public let status: MirageLabRunStatus
    public let metrics: [MirageLabMetric]
    public let artifacts: [MirageLabArtifact]
    public let warnings: [String]
    public let invalidationReasons: [String]

    public init(
        id: UUID = UUID(),
        schemaVersion: Int = MirageLabReportSchema.currentVersion,
        labID: String,
        labTitle: String,
        category: MirageLabCategory,
        configuration: MirageLabConfiguration,
        measuredAt: Date = Date(),
        status: MirageLabRunStatus,
        metrics: [MirageLabMetric] = [],
        artifacts: [MirageLabArtifact] = [],
        warnings: [String] = [],
        invalidationReasons: [String] = []
    ) {
        self.id = id
        self.schemaVersion = schemaVersion
        self.labID = labID
        self.labTitle = labTitle
        self.category = category
        self.configuration = configuration
        self.measuredAt = measuredAt
        self.status = status
        self.metrics = metrics
        self.artifacts = artifacts
        self.warnings = warnings
        self.invalidationReasons = invalidationReasons
    }
}
