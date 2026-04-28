//
//  MirageLogRecorder.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/14/26.
//

import Foundation

// MARK: - Configuration

public final class MirageLogRecorder: @unchecked Sendable {
    public struct Configuration: Sendable {
        public let logFilename: String
        public let logsDirectoryName: String
        public let retentionDays: Int
        public let maxLogBytes: Int
        public let headLogBytes: Int
        public let useApplicationSupport: Bool
        public let queueLabel: String
        public let truncationLabel: String
        public let baselineCategories: Set<LoomLogCategory>

        public init(
            logFilename: String,
            logsDirectoryName: String,
            retentionDays: Int,
            maxLogBytes: Int,
            headLogBytes: Int,
            useApplicationSupport: Bool,
            queueLabel: String,
            truncationLabel: String,
            baselineCategories: Set<LoomLogCategory>
        ) {
            self.logFilename = logFilename
            self.logsDirectoryName = logsDirectoryName
            self.retentionDays = retentionDays
            self.maxLogBytes = maxLogBytes
            self.headLogBytes = headLogBytes
            self.useApplicationSupport = useApplicationSupport
            self.queueLabel = queueLabel
            self.truncationLabel = truncationLabel
            self.baselineCategories = baselineCategories
        }

        public static let client = Configuration(
            logFilename: "MirageClient.log",
            logsDirectoryName: "MirageLogs",
            retentionDays: 3,
            maxLogBytes: 2 * 1024 * 1024,
            headLogBytes: 256 * 1024,
            useApplicationSupport: false,
            queueLabel: "com.mirage.client.log.recorder",
            truncationLabel: "Mirage",
            baselineCategories: Set(
                [
                    MirageLogCategory.host,
                    MirageLogCategory.client,
                    MirageLogCategory.appState,
                    MirageLogCategory.stream,
                    MirageLogCategory.decoder,
                    MirageLogCategory.renderer,
                ].map { LoomLogCategory(rawValue: $0.rawValue) }
            )
        )

        public static let host = Configuration(
            logFilename: "LoomPeer.log",
            logsDirectoryName: "MirageLogs",
            retentionDays: 7,
            maxLogBytes: 5 * 1024 * 1024,
            headLogBytes: 512 * 1024,
            useApplicationSupport: true,
            queueLabel: "com.mirage.host.log.recorder",
            truncationLabel: "Mirage Host",
            baselineCategories: Set(
                [
                    MirageLogCategory.host,
                    MirageLogCategory.appState,
                    MirageLogCategory.stream,
                    MirageLogCategory.capture,
                    MirageLogCategory.encoder,
                    MirageLogCategory.timing,
                    MirageLogCategory.metrics,
                ].map { LoomLogCategory(rawValue: $0.rawValue) }
            )
        )
    }

    private let queue: DispatchQueue
    private let fileManager = FileManager.default
    private let formatter = ISO8601DateFormatter()
    private let configuration: Configuration
    private var sinkToken: LoomDiagnosticsSinkToken?
    private var hasActivated = false
    private var hasPreparedCurrentSessionLogFile = false

    private static let shouldRecordVerboseLogs: Bool = {
        #if DEBUG
        return true
        #else
        guard let envValue = ProcessInfo.processInfo.environment["MIRAGE_LOG"] else { return false }
        let trimmed = envValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed != "none" && !trimmed.isEmpty
        #endif
    }()

    private var logURL: URL { logsDirectoryURL.appending(path: configuration.logFilename) }

    private var logsDirectoryURL: URL {
        if configuration.useApplicationSupport {
            return URL.applicationSupportDirectory.appending(
                path: configuration.logsDirectoryName,
                directoryHint: .isDirectory
            )
        }
        return URL.documentsDirectory.appending(path: configuration.logsDirectoryName, directoryHint: .isDirectory)
    }

    // MARK: - Initialization

    public init(configuration: Configuration) {
        self.configuration = configuration
        self.queue = DispatchQueue(label: configuration.queueLabel, qos: .utility)
    }

    // MARK: - Activation

    public func activate() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                do {
                    try fileManager.createDirectory(at: logsDirectoryURL, withIntermediateDirectories: true)
                    purgeExpiredLogsIfNeeded()
                    try prepareCurrentSessionLogFileIfNeeded()
                } catch {
                    continuation.resume()
                    return
                }

                continuation.resume()
            }
        }

        guard !hasActivated else { return }
        if let sinkToken {
            await LoomDiagnostics.removeSink(sinkToken)
        }
        sinkToken = await LoomDiagnostics.addSink(self)
        hasActivated = true
    }

    // MARK: - Recording

    public func record(log entry: LoomDiagnosticsLogEvent) async {
        if entry.level == .info || entry.level == .debug {
            guard Self.shouldRecordVerboseLogs || configuration.baselineCategories.contains(entry.category) else { return }
        }
        appendEntry(entry)
    }

    public func record(error _: LoomDiagnosticsErrorEvent) async {}

    // MARK: - Export

    public func exportLogArchive(
        filename: String,
        maximumCompressedBytes: Int,
        emptyStateMessage: String,
        diagnosticsSummary: String? = nil
    ) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                do {
                    let filteredLogData = try currentSessionLogData(emptyStateMessage: emptyStateMessage)
                    let archiveURL = try MirageLogArchiver.exportArchive(
                        from: filteredLogData,
                        filename: filename,
                        maximumCompressedBytes: maximumCompressedBytes,
                        truncationLabel: configuration.truncationLabel,
                        diagnosticsSummary: diagnosticsSummary
                    )
                    continuation.resume(returning: archiveURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - File Management

    private func prepareCurrentSessionLogFileIfNeeded() throws {
        guard !hasPreparedCurrentSessionLogFile else {
            if !fileManager.fileExists(atPath: logURL.path) {
                fileManager.createFile(atPath: logURL.path, contents: nil)
            }
            return
        }

        if fileManager.fileExists(atPath: logURL.path) {
            try fileManager.removeItem(at: logURL)
        }
        fileManager.createFile(atPath: logURL.path, contents: nil)
        hasPreparedCurrentSessionLogFile = true
    }

    private func currentSessionLogData(emptyStateMessage: String) throws -> Data {
        guard fileManager.fileExists(atPath: logURL.path) else {
            return Data("\(emptyStateMessage)\n".utf8)
        }

        let sourceData = try Data(contentsOf: logURL)
        guard !sourceData.isEmpty else {
            return Data("\(emptyStateMessage)\n".utf8)
        }
        return sourceData
    }

    private func purgeExpiredLogsIfNeeded() {
        do {
            let urls = try fileManager.contentsOfDirectory(
                at: logsDirectoryURL,
                includingPropertiesForKeys: [.creationDateKey]
            )
            let expirationDate = Date().addingTimeInterval(-TimeInterval(configuration.retentionDays * 24 * 60 * 60))
            for url in urls {
                guard let creationDate = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate else { continue }
                if creationDate < expirationDate { try? fileManager.removeItem(at: url) }
            }
        } catch {
            return
        }
    }

    private func formattedLine(for entry: LoomDiagnosticsLogEvent) -> String {
        let timestamp = formatter.string(from: entry.date)
        return "[\(timestamp)] [\(entry.category.rawValue)] [\(entry.level.rawValue)] \(entry.message)\n"
    }

    private func appendEntry(_ entry: LoomDiagnosticsLogEvent) {
        let line = formattedLine(for: entry)
        guard let data = line.data(using: .utf8) else { return }

        queue.async { [weak self] in
            guard let self else { return }
            do {
                if !fileManager.fileExists(atPath: logURL.path) {
                    fileManager.createFile(atPath: logURL.path, contents: nil)
                }

                let fileHandle = try FileHandle(forWritingTo: logURL)
                try fileHandle.seekToEnd()
                try fileHandle.write(contentsOf: data)
                try fileHandle.close()
                trimIfNeeded()
            } catch {
                return
            }
        }
    }

    private func trimIfNeeded() {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: logURL.path)
            guard let fileSize = attributes[.size] as? NSNumber else { return }
            let currentSize = fileSize.intValue
            guard currentSize > configuration.maxLogBytes else { return }

            let fileHandle = try FileHandle(forReadingFrom: logURL)
            let data = try fileHandle.readToEnd() ?? Data()
            try fileHandle.close()

            guard !data.isEmpty else {
                try fileManager.removeItem(at: logURL)
                fileManager.createFile(atPath: logURL.path, contents: nil)
                return
            }

            let headBytes = min(configuration.headLogBytes, data.count)
            let suffixStart = min(data.count, max(0, data.count - configuration.headLogBytes))
            let prefix = data.prefix(headBytes)
            let suffix = data.suffix(from: suffixStart)
            var trimmed = Data()
            trimmed.append(prefix)
            trimmed.append("\n... trimmed ...\n".data(using: .utf8) ?? Data())
            trimmed.append(suffix)
            try trimmed.write(to: logURL, options: .atomic)
        } catch {
            return
        }
    }
}

// MARK: - LoomDiagnosticsSink

extension MirageLogRecorder: LoomDiagnosticsSink {}
