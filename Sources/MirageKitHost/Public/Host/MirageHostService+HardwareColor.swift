//
//  MirageHostService+HardwareColor.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//
//  Host enclosure color metadata.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
import Foundation

#if os(macOS)
extension MirageHostService {
    /// Reads the host enclosure color code from IORegistry when the platform exposes it.
    static func hardwareColorCode() -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-lw0", "-p", "IODeviceTree", "-n", "chosen", "-r"]

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Drain stdout before waiting for exit so the child cannot block when
        // writing large IORegistry payloads.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return nil
        }

        guard let output = String(data: outputData, encoding: .utf8) else {
            return nil
        }

        return parseHousingColorCode(from: output)
    }

    /// Parses IORegistry's little-endian `housing-color` payload into the last nonzero color code.
    static func parseHousingColorCode(from output: String) -> Int? {
        let pattern = #""housing-color"\s*=\s*<([0-9A-Fa-f]+)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsOutput = output as NSString
        let range = NSRange(location: 0, length: nsOutput.length)
        guard let match = regex.firstMatch(in: output, range: range), match.numberOfRanges > 1 else {
            return nil
        }

        let hexRange = match.range(at: 1)
        guard hexRange.location != NSNotFound else {
            return nil
        }

        let hexString = nsOutput.substring(with: hexRange)
        let bytes = hexBytes(from: hexString)
        guard !bytes.isEmpty else {
            return nil
        }

        var values: [UInt32] = []
        let stride = 4
        let usableLength = bytes.count - (bytes.count % stride)
        guard usableLength >= stride else {
            return nil
        }

        var index = 0
        while index + 3 < usableLength {
            let value = UInt32(bytes[index]) |
                (UInt32(bytes[index + 1]) << 8) |
                (UInt32(bytes[index + 2]) << 16) |
                (UInt32(bytes[index + 3]) << 24)
            values.append(value)
            index += stride
        }

        guard let resolved = values.last(where: { $0 != 0 }) else {
            return nil
        }
        return Int(resolved)
    }

    private static func hexBytes(from value: String) -> [UInt8] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count.isMultiple(of: 2) else {
            return []
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(trimmed.count / 2)

        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            let nextIndex = trimmed.index(index, offsetBy: 2)
            let pair = trimmed[index ..< nextIndex]
            guard let byte = UInt8(pair, radix: 16) else {
                return []
            }
            bytes.append(byte)
            index = nextIndex
        }

        return bytes
    }
}
#endif
