//
//  MirageLogArchiver.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/14/26.
//

import Foundation
import zlib

// MARK: - ZIP Archive Creation

enum MirageLogArchiver {
    static func exportArchive(
        from logData: Data,
        filename: String,
        maximumCompressedBytes: Int,
        truncationLabel: String,
        diagnosticsSummary: String? = nil
    ) throws -> URL {
        let archiveURL = FileManager.default.temporaryDirectory.appending(path: "\(filename).zip")
        let fitted = try fittedLogData(
            from: logData,
            filename: filename,
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: truncationLabel
        )

        if FileManager.default.fileExists(atPath: archiveURL.path) {
            try FileManager.default.removeItem(at: archiveURL)
        }

        var entries = [(name: "\(filename).log", data: fitted)]
        if let diagnosticsSummary = MirageSupportInfo.trimmedValue(diagnosticsSummary) {
            entries.append((name: "DiagnosticsSummary.txt", data: Data("\(diagnosticsSummary)\n".utf8)))
        }
        let archiveData = try zipArchiveData(entries: entries)
        try archiveData.write(to: archiveURL, options: .atomic)
        return archiveURL
    }

    // MARK: - Log Fitting

    static func fittedLogData(
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

    static func truncatedLogData(
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

    static func truncationMarker(
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

    static func minimalLogData(maximumCompressedBytes: Int, truncationLabel: String) -> Data {
        let message = truncationMarker(
            removedLineCount: 0,
            maximumCompressedBytes: maximumCompressedBytes,
            truncationLabel: truncationLabel
        )
        return Data("\(message)\n".utf8)
    }

    static func encodedLogData(from lines: [String]) -> Data {
        guard !lines.isEmpty else { return Data() }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    // MARK: - ZIP Archive

    static func zipArchiveData(for logData: Data, entryName: String) throws -> Data {
        try zipArchiveData(entries: [(name: entryName, data: logData)])
    }

    static func zipArchiveData(entries: [(name: String, data: Data)]) throws -> Data {
        var archiveData = Data()
        var centralDirectoryRecords = Data()

        for entry in entries {
            let localHeaderOffset = try checkedZIPSize(archiveData.count)
            let record = try zipLocalFileRecord(for: entry.data, entryName: entry.name)
            archiveData.append(record.localFile)
            centralDirectoryRecords.append(
                try zipCentralDirectoryRecord(
                    for: record,
                    localHeaderOffset: localHeaderOffset
                )
            )
        }

        let centralDirectoryOffset = try checkedZIPSize(archiveData.count)
        archiveData.append(centralDirectoryRecords)
        let centralDirectorySize = try checkedZIPSize(centralDirectoryRecords.count)
        let entryCount = try checkedZIPEntryCount(entries.count)

        archiveData.appendLittleEndian(UInt32(0x06054b50))
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

        var localFile = Data()
        localFile.appendLittleEndian(UInt32(0x04034b50))
        localFile.appendLittleEndian(UInt16(20))
        localFile.appendLittleEndian(UInt16(0))
        localFile.appendLittleEndian(UInt16(8))
        localFile.appendLittleEndian(timestamp.time)
        localFile.appendLittleEndian(timestamp.date)
        localFile.appendLittleEndian(checksum)
        localFile.appendLittleEndian(compressedSize)
        localFile.appendLittleEndian(uncompressedSize)
        localFile.appendLittleEndian(try checkedZIPNameLength(entryNameData.count))
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
        centralDirectory.appendLittleEndian(UInt32(0x02014b50))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(20))
        centralDirectory.appendLittleEndian(UInt16(0))
        centralDirectory.appendLittleEndian(UInt16(8))
        centralDirectory.appendLittleEndian(record.timestamp.time)
        centralDirectory.appendLittleEndian(record.timestamp.date)
        centralDirectory.appendLittleEndian(record.checksum)
        centralDirectory.appendLittleEndian(record.compressedSize)
        centralDirectory.appendLittleEndian(record.uncompressedSize)
        centralDirectory.appendLittleEndian(try checkedZIPNameLength(record.entryNameData.count))
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

    private static func checkedZIPNameLength(_ value: Int) throws -> UInt16 {
        guard value <= Int(UInt16.max) else {
            throw LogArchiveError.sizeOverflow
        }
        return UInt16(value)
    }

    private static func checkedZIPEntryCount(_ value: Int) throws -> UInt16 {
        guard value <= Int(UInt16.max) else {
            throw LogArchiveError.sizeOverflow
        }
        return UInt16(value)
    }
}

// MARK: - Errors

enum LogArchiveError: Error {
    case compressionFailed(Int32)
    case invalidBuffer
    case sizeOverflow
}

// MARK: - Data Helpers

extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndianValue = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndianValue) { buffer in
            append(buffer.bindMemory(to: UInt8.self))
        }
    }
}
