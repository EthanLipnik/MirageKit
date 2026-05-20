//
//  MirageLogRecorderTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/20/26.
//

import Foundation
@testable import MirageKit
import Testing

@Suite("Mirage Log Recorder")
struct MirageLogRecorderTests {
    @Test("Recorder rotates previous session log into support archive")
    func recorderRotatesPreviousSessionLogIntoSupportArchive() async throws {
        let directoryName = "MirageLogRecorderTests-\(UUID().uuidString)"
        let logsDirectory = URL.documentsDirectory.appending(path: directoryName, directoryHint: .isDirectory)
        let logURL = logsDirectory.appending(path: "TestClient.log")
        try FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        try Data("previous-session\n".utf8).write(to: logURL)

        let recorder = MirageLogRecorder(
            configuration: .init(
                logFilename: "TestClient.log",
                logsDirectoryName: directoryName,
                retentionDays: 1,
                maxLogBytes: 128 * 1024,
                headLogBytes: 16 * 1024,
                useApplicationSupport: false,
                queueLabel: "com.mirage.tests.log-recorder.\(UUID().uuidString)",
                truncationLabel: "Mirage",
                baselineCategories: []
            )
        )
        await recorder.activate()

        let archiveURL = try await recorder.exportLogArchive(
            filename: "MirageLogRecorderArchive-\(UUID().uuidString)",
            maximumCompressedBytes: 128 * 1024,
            emptyStateMessage: "empty",
            includePreviousSessionLog: true
        )
        let archive = try Data(contentsOf: archiveURL)

        #expect(archive.contains(Data("PreviousSession.log".utf8)))

        try? FileManager.default.removeItem(at: logsDirectory)
        try? FileManager.default.removeItem(at: archiveURL)
    }
}
