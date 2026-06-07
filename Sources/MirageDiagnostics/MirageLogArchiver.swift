//
//  MirageLogArchiver.swift
//  MirageDiagnostics
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import zlib

// MARK: - ZIP Archive Creation

package enum MirageLogArchiver {
    private struct ArchiveEntry {
        let name: String
        var data: Data
        let truncationLabel: String
        let canDrop: Bool
    }

    /// Writes a ZIP archive containing the current log and optional diagnostics summary.
    ///
    /// The log entry is trimmed before archiving when its compressed ZIP entry would
    /// exceed `maximumCompressedBytes`.
    package static func exportArchive(
        from logData: Data,
        filename: String,
        maximumCompressedBytes: Int,
        truncationLabel: String,
        diagnosticsSummary: String? = nil,
        additionalEntries: [MirageLogArchiveEntry] = []
    ) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory.appending(path: "\(filename).zip")

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }

        var entries = [
            ArchiveEntry(
                name: "\(filename).log",
                data: logData,
                truncationLabel: truncationLabel,
                canDrop: false
            ),
        ]
        if let diagnosticsSummary = trimmedValue(diagnosticsSummary) {
            entries.append(
                ArchiveEntry(
                    name: "DiagnosticsSummary.txt",
                    data: Data("\(diagnosticsSummary)\n".utf8),
                    truncationLabel: "Diagnostics summary",
                    canDrop: false
                )
            )
        }
        entries.append(
            contentsOf: additionalEntries.map {
                ArchiveEntry(
                    name: $0.name,
                    data: $0.data,
                    truncationLabel: $0.name,
                    canDrop: true
                )
            }
        )

        let fittedEntries = try fittedArchiveEntries(
            entries,
            maximumCompressedBytes: maximumCompressedBytes
        )
        let archiveData = try zipArchiveData(entries: fittedEntries.map { (name: $0.name, data: $0.data) })
        try archiveData.write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    // MARK: - Log Fitting

    private static func fittedArchiveEntries(
        _ entries: [ArchiveEntry],
        maximumCompressedBytes: Int
    ) throws -> [ArchiveEntry] {
        guard !entries.isEmpty else { return entries }
        var fitted = entries
        guard try zipArchiveData(entries: fitted.map { (name: $0.name, data: $0.data) }).count > maximumCompressedBytes else {
            return fitted
        }

        for index in fitted.indices.reversed() {
            fitted[index].data = try fittedEntryData(
                entry: fitted[index],
                in: fitted,
                entryIndex: index,
                maximumCompressedBytes: maximumCompressedBytes
            )
            if try zipArchiveData(entries: fitted.map { (name: $0.name, data: $0.data) }).count <= maximumCompressedBytes {
                return fitted
            }
            if fitted[index].canDrop {
                fitted.remove(at: index)
                if try zipArchiveData(entries: fitted.map { (name: $0.name, data: $0.data) }).count <= maximumCompressedBytes {
                    return fitted
                }
            }
        }

        guard let first = fitted.indices.first else { return fitted }
        fitted[first].data = minimalLogData(
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: fitted[first].truncationLabel
        )
        return fitted
    }

    private static func fittedEntryData(
        entry: ArchiveEntry,
        in entries: [ArchiveEntry],
        entryIndex: Int,
        maximumCompressedBytes: Int
    ) throws -> Data {
        guard let contents = String(data: entry.data, encoding: .utf8) else {
            return entry.data
        }
        let lines = contents
            .split(omittingEmptySubsequences: false) { $0.isNewline }
            .map(String.init)
        guard !lines.isEmpty else { return entry.data }

        var lowerBound = 0
        var upperBound = lines.count
        var bestCandidate: Data?

        while lowerBound <= upperBound {
            let keptLineCount = (lowerBound + upperBound) / 2
            let candidateData = truncatedLogData(
                lines: lines,
                keeping: keptLineCount,
                maximumCompressedBytes: maximumCompressedBytes,
                truncationLabel: entry.truncationLabel
            )
            var candidateEntries = entries
            candidateEntries[entryIndex].data = candidateData
            let candidateArchiveSize = try zipArchiveData(
                entries: candidateEntries.map { (name: $0.name, data: $0.data) }
            ).count

            if candidateArchiveSize <= maximumCompressedBytes {
                bestCandidate = candidateData
                lowerBound = keptLineCount + 1
            } else {
                upperBound = keptLineCount - 1
            }
        }

        return bestCandidate ?? minimalLogData(
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: entry.truncationLabel
        )
    }

    /// Returns log data that fits inside a compressed single-entry ZIP archive.
    package static func fittedLogData(
        from logData: Data,
        filename: String,
        maximumCompressedBytes: Int,
        truncationLabel: String
    ) throws -> Data {
        let fullArchiveSize = try zipArchiveData(for: logData, entryName: "\(filename).log").count
        guard fullArchiveSize > maximumCompressedBytes else { return logData }
        guard let contents = String(data: logData, encoding: .utf8) else { return logData }

        let lines = contents
            .split(omittingEmptySubsequences: false) { $0.isNewline }
            .map(String.init)

        guard !lines.isEmpty else { return logData }

        var lowerBound = 0
        var upperBound = lines.count
        var bestCandidate: Data?

        while lowerBound <= upperBound {
            let keptLineCount = (lowerBound + upperBound) / 2
            let candidateData = truncatedLogData(
                lines: lines,
                keeping: keptLineCount,
                maximumCompressedBytes: maximumCompressedBytes,
                truncationLabel: truncationLabel
            )
            let candidateArchiveSize = try zipArchiveData(for: candidateData, entryName: "\(filename).log").count

            if candidateArchiveSize <= maximumCompressedBytes {
                bestCandidate = candidateData
                lowerBound = keptLineCount + 1
            } else {
                upperBound = keptLineCount - 1
            }
        }

        return bestCandidate ?? minimalLogData(
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: truncationLabel
        )
    }

    // MARK: - Truncation

    /// Keeps the beginning and end of a log while replacing removed middle lines with a marker.
    package static func truncatedLogData(
        lines: [String],
        keeping keptLineCount: Int,
        maximumCompressedBytes: Int,
        truncationLabel: String
    ) -> Data {
        guard !lines.isEmpty else { return Data() }
        guard keptLineCount < lines.count else { return encodedLogData(from: lines) }

        let normalizedKeptLineCount = min(max(keptLineCount, 1), lines.count)
        let headCount = max(1, (normalizedKeptLineCount + 1) / 2)
        let tailCount = min(
            max(0, normalizedKeptLineCount - headCount),
            max(0, lines.count - headCount)
        )
        let removedLineCount = max(0, lines.count - headCount - tailCount)

        var preservedLines = Array(lines.prefix(headCount))
        if removedLineCount > 0 {
            preservedLines.append(
                truncationMarker(
                    removedLineCount: removedLineCount,
                    maximumCompressedBytes: maximumCompressedBytes,
                    truncationLabel: truncationLabel
                )
            )
        }
        if tailCount > 0 {
            preservedLines.append(contentsOf: lines.suffix(tailCount))
        }

        return encodedLogData(from: preservedLines)
    }

    /// Human-readable marker inserted when support log export trims the middle of a log.
    package static func truncationMarker(
        removedLineCount: Int,
        maximumCompressedBytes: Int,
        truncationLabel: String
    ) -> String {
        let sizeLimit = ByteCountFormatter.string(fromByteCount: Int64(maximumCompressedBytes), countStyle: .file)

        if removedLineCount > 0 {
            return "... \(truncationLabel) support export trimmed \(removedLineCount) middle log lines to stay under \(sizeLimit) compressed ..."
        }

        return "... \(truncationLabel) support export was reduced to fit within \(sizeLimit) compressed ..."
    }

    /// Smallest fallback log body used when no head/tail split can fit the compressed limit.
    package static func minimalLogData(maximumCompressedBytes: Int, truncationLabel: String) -> Data {
        let message = truncationMarker(
            removedLineCount: 0,
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: truncationLabel
        )
        return Data("\(message)\n".utf8)
    }

    /// Encodes log lines with the trailing newline expected by text editors and log viewers.
    package static func encodedLogData(from lines: [String]) -> Data {
        guard !lines.isEmpty else { return Data() }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - ZIP Archive

    /// Builds a single-entry ZIP archive for sizing tests and log export.
    package static func zipArchiveData(for logData: Data, entryName: String) throws -> Data {
        try zipArchiveData(entries: [(name: entryName, data: logData)])
    }

    /// Builds an in-memory deflated ZIP archive for the supplied entries.
    package static func zipArchiveData(entries: [(name: String, data: Data)]) throws -> Data {
        var archiveData = Data()
        var centralDirectoryRecords = Data()

        for entry in entries {
            let localHeaderOffset = try checkedZIPSize(archiveData.count)
            let record = try zipLocalFileRecord(for: entry.data, entryName: entry.name)
            archiveData.append(record.localFile)
            try centralDirectoryRecords.append(
                zipCentralDirectoryRecord(
                    for: record,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        let centralDirectoryOffset = try checkedZIPSize(archiveData.count)
        archiveData.append(centralDirectoryRecords)
        let centralDirectorySize = try checkedZIPSize(centralDirectoryRecords.count)
        let entryCount = try checkedZIPUInt16(entries.count)

        archiveData.appendLittleEndian(UInt32(0x0605_4B50))
        archiveData.appendLittleEndian(UInt16(0))
        archiveData.appendLittleEndian(UInt16(0))
        archiveData.appendLittleEndian(entryCount)
        archiveData.appendLittleEndian(entryCount)
        archiveData.appendLittleEndian(centralDirectorySize)
        archiveData.appendLittleEndian(centralDirectoryOffset)
        archiveData.appendLittleEndian(UInt16(0))

        return archiveData
    }

    private struct ZIPLocalFileRecord {
        let localFile: Data
        let entryNameData: Data
        let checksum: UInt32
        let compressedSize: UInt32
        let uncompressedSize: UInt32
        let timestamp: (time: UInt16, date: UInt16)
    }

    private static func zipLocalFileRecord(for logData: Data, entryName: String) throws -> ZIPLocalFileRecord {
        let compressedData = try deflated(logData)
        let checksum = crc32Value(for: logData)
        let timestamp = dosDateTime(for: Date())
        let entryNameData = Data(entryName.utf8)
        let compressedSize = try checkedZIPSize(compressedData.count)
        let uncompressedSize = try checkedZIPSize(logData.count)
        let entryNameLength = try checkedZIPUInt16(entryNameData.count)

        var localFile = Data()
        localFile.appendLittleEndian(UInt32(0x0403_4B50))
        localFile.appendLittleEndian(UInt16(20))
        localFile.appendLittleEndian(UInt16(0))
        localFile.appendLittleEndian(UInt16(8))
        localFile.appendLittleEndian(timestamp.time)
        localFile.appendLittleEndian(timestamp.date)
        localFile.appendLittleEndian(checksum)
        localFile.appendLittleEndian(compressedSize)
        localFile.appendLittleEndian(uncompressedSize)
        localFile.appendLittleEndian(entryNameLength)
        localFile.appendLittleEndian(UInt16(0))
        localFile.append(entryNameData)
        localFile.append(compressedData)

        return ZIPLocalFileRecord(
            localFile: localFile,
            entryNameData: entryNameData,
            checksum: checksum,
            compressedSize: compressedSize,
            uncompressedSize: uncompressedSize,
            timestamp: timestamp
        )
    }

    private static func zipCentralDirectoryRecord(
        for record: ZIPLocalFileRecord,
        localHeaderOffset: UInt32
    ) throws -> Data {
        var centralDirectory = Data()
        centralDirectory.appendLittleEndian(UInt32(0x0201_4B50))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(8))
        centralDirectory.appendLittleEndian(record.timestamp.time)
        centralDirectory.appendLittleEndian(record.timestamp.date)
        centralDirectory.appendLittleEndian(record.checksum)
        centralDirectory.appendLittleEndian(record.compressedSize)
        centralDirectory.appendLittleEndian(record.uncompressedSize)
        try centralDirectory.appendLittleEndian(checkedZIPUInt16(record.entryNameData.count))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt32(0))
        centralDirectory.appendLittleEndian(localHeaderOffset)
        centralDirectory.append(record.entryNameData)
        return centralDirectory
    }

    // MARK: - Compression

    private static func deflated(_ data: Data) throws -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            -MAX_WBITS,
            MAX_MEM_LEVEL,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw LogArchiveError.compressionFailed(status)
        }
        defer {
            deflateEnd(&stream)
        }

        let chunkSize = 64 * 1024
        var compressedData = Data()

        try data.withUnsafeBytes { rawBuffer in
            let inputBaseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress
            stream.next_in = UnsafeMutablePointer(mutating: inputBaseAddress)
            stream.avail_in = uInt(data.count)

            repeat {
                var buffer = [UInt8](repeating: 0, count: chunkSize)
                let producedCount = try buffer.withUnsafeMutableBytes { outputBuffer -> Int in
                    guard let outputBaseAddress = outputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                        throw LogArchiveError.invalidBuffer
                    }

                    stream.next_out = outputBaseAddress
                    stream.avail_out = uInt(chunkSize)

                    let streamStatus = deflate(&stream, Z_FINISH)
                    switch streamStatus {
                    case Z_OK, Z_STREAM_END:
                        return chunkSize - Int(stream.avail_out)
                    default:
                        throw LogArchiveError.compressionFailed(streamStatus)
                    }
                }

                compressedData.append(buffer, count: producedCount)
            } while stream.avail_out == 0
        }

        return compressedData
    }

    private static func crc32Value(for data: Data) -> UInt32 {
        data.withUnsafeBytes { rawBuffer in
            let baseAddress = rawBuffer.bindMemory(to: Bytef.self).baseAddress
            return UInt32(crc32(0, baseAddress, uInt(data.count)))
        }
    }

    private static func dosDateTime(for date: Date) -> (time: UInt16, date: UInt16) {
        let components = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let year = max(1980, components.year ?? 1980)
        let month = max(1, components.month ?? 1)
        let day = max(1, components.day ?? 1)
        let hour = max(0, components.hour ?? 0)
        let minute = max(0, components.minute ?? 0)
        let second = max(0, components.second ?? 0)

        let dosTime = UInt16((hour << 11) | (minute << 5) | (second / 2))
        let dosDate = UInt16(((year - 1980) << 9) | (month << 5) | day)
        return (dosTime, dosDate)
    }

    private static func checkedZIPSize(_ value: Int) throws -> UInt32 {
        guard value <= Int(UInt32.max) else {
            throw LogArchiveError.sizeOverflow
        }
        return UInt32(value)
    }

    private static func checkedZIPUInt16(_ value: Int) throws -> UInt16 {
        guard value <= Int(UInt16.max) else {
            throw LogArchiveError.sizeOverflow
        }
        return UInt16(value)
    }

    private static func trimmedValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

// MARK: - Errors

private enum LogArchiveError: Error {
    case compressionFailed(Int32)
    case invalidBuffer
    case sizeOverflow
}

// MARK: - Data Helpers

private extension Data {
    mutating func appendLittleEndian(_ value: some FixedWidthInteger) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }
}
