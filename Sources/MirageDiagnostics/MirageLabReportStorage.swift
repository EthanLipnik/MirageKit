//
//  MirageLabReportStorage.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Stored Lab report and the file that contains it.
@_spi(Labs)
public struct MirageStoredLabReport: Sendable {
    public let report: MirageLabReport
    public let fileURL: URL

    public init(report: MirageLabReport, fileURL: URL) {
        self.report = report
        self.fileURL = fileURL
    }
}

/// Storage abstraction for Lab reports.
@_spi(Labs)
public protocol MirageLabReportStorage {
    func save(_ report: MirageLabReport) throws -> MirageStoredLabReport
    func loadReport(id: UUID) throws -> MirageStoredLabReport?
    func reportFileURL(id: UUID) -> URL
}

/// JSON file storage for generic Lab reports.
@_spi(Labs)
public struct MirageJSONLabReportStore: MirageLabReportStorage {
    public let directoryURL: URL

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public func save(_ report: MirageLabReport) throws -> MirageStoredLabReport {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )

        let fileURL = reportFileURL(id: report.id)
        let data = try Self.exportData(for: report)
        try data.write(to: fileURL, options: .atomic)
        return MirageStoredLabReport(report: report, fileURL: fileURL)
    }

    public func loadReport(id: UUID) throws -> MirageStoredLabReport? {
        let fileURL = reportFileURL(id: id)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return nil
        }

        let data = try Data(contentsOf: fileURL)
        let report = try Self.decoder.decode(MirageLabReport.self, from: data)
        return MirageStoredLabReport(report: report, fileURL: fileURL)
    }

    public func reportFileURL(id: UUID) -> URL {
        directoryURL.appendingPathComponent(
            "MirageLabReport-\(id.uuidString).json",
            isDirectory: false
        )
    }

    public static func exportData(for report: MirageLabReport) throws -> Data {
        try encoder.encode(report)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
