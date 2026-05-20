//
//  MirageLogArchiverTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/11/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("Mirage Log Archiver")
struct MirageLogArchiverTests {
    @Test("Truncation keeps log head tail and marker")
    func truncationKeepsLogHeadTailAndMarker() throws {
        let lines = (1 ... 8).map { "line-\($0)" }
        let data = MirageLogArchiver.truncatedLogData(
            lines: lines,
            keeping: 4,
            maximumCompressedBytes: 512,
            truncationLabel: "Host"
        )

        let output = try #require(String(data: data, encoding: .utf8))
        #expect(output.hasPrefix("line-1\nline-2\n"))
        #expect(output.contains("Host support export trimmed 4 middle log lines"))
        #expect(output.hasSuffix("line-7\nline-8\n"))
    }

    @Test("ZIP archive contains local central directory and end records")
    func zipArchiveContainsExpectedRecords() throws {
        let archive = try MirageLogArchiver.zipArchiveData(
            entries: [
                (name: "Mirage.log", data: Data("hello\n".utf8)),
                (name: "DiagnosticsSummary.txt", data: Data("summary\n".utf8)),
            ]
        )

        #expect(archive.starts(withLittleEndian: 0x0403_4B50))
        #expect(archive.containsLittleEndian(0x0201_4B50))
        #expect(archive.containsLittleEndian(0x0605_4B50))
        #expect(archive.contains(Data("Mirage.log".utf8)))
        #expect(archive.contains(Data("DiagnosticsSummary.txt".utf8)))
    }

    @Test("Support archive can include additional prioritized entries")
    func supportArchiveIncludesAdditionalEntries() throws {
        let archiveURL = try MirageLogArchiver.exportArchive(
            from: Data("current\n".utf8),
            filename: "MirageLogArchiverAdditionalEntries",
            maximumCompressedBytes: 128 * 1024,
            truncationLabel: "Mirage",
            diagnosticsSummary: "summary",
            additionalEntries: [
                MirageLogArchiveEntry(name: "MetricKitDiagnostics.txt", text: "metric\n"),
                MirageLogArchiveEntry(name: "PreviousSession.log", text: "previous\n"),
            ]
        )
        let archive = try Data(contentsOf: archiveURL)

        #expect(archive.contains(Data("MirageLogArchiverAdditionalEntries.log".utf8)))
        #expect(archive.contains(Data("DiagnosticsSummary.txt".utf8)))
        #expect(archive.contains(Data("MetricKitDiagnostics.txt".utf8)))
        #expect(archive.contains(Data("PreviousSession.log".utf8)))
    }
}

private extension Data {
    func starts(withLittleEndian value: UInt32) -> Bool {
        starts(with: Data(littleEndianBytes: value))
    }

    func containsLittleEndian(_ value: UInt32) -> Bool {
        range(of: Data(littleEndianBytes: value)) != nil
    }

    init(littleEndianBytes value: UInt32) {
        var littleEndianValue = value.littleEndian
        self = Swift.withUnsafeBytes(of: &littleEndianValue) { Data($0) }
    }
}
