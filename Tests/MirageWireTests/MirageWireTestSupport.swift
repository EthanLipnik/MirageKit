//
//  MirageWireTestSupport.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation
import MirageWire

enum WireTestError: Error {
    case invalidHex
    case invalidControlFrame
}

func data(hex: String) throws -> Data {
    let cleaned = hex.filter { !$0.isWhitespace }
    guard cleaned.count.isMultiple(of: 2) else {
        throw WireTestError.invalidHex
    }

    var bytes = Data()
    bytes.reserveCapacity(cleaned.count / 2)

    var index = cleaned.startIndex
    while index < cleaned.endIndex {
        let next = cleaned.index(index, offsetBy: 2)
        guard let byte = UInt8(cleaned[index ..< next], radix: 16) else {
            throw WireTestError.invalidHex
        }
        bytes.append(byte)
        index = next
    }

    return bytes
}

func controlFrame(type: MirageWire.ControlMessageType, declaredPayloadLength: UInt32) -> Data {
    var data = Data([type.rawValue])
    withUnsafeBytes(of: declaredPayloadLength.littleEndian) {
        data.append(contentsOf: $0)
    }
    return data
}

func parsedControlMessage(from data: Data) throws -> (message: MirageWire.ControlMessage, bytesConsumed: Int) {
    switch MirageWire.ControlMessage.deserialize(from: data) {
    case let .success(message, bytesConsumed):
        return (message, bytesConsumed)
    case .needMoreData, .invalidFrame:
        throw WireTestError.invalidControlFrame
    }
}

func softwareUpdateStatus() -> MirageWire.HostSoftwareUpdateStatusMessage {
    MirageWire.HostSoftwareUpdateStatusMessage(
        isSparkleAvailable: true,
        isCheckingForUpdates: false,
        isInstallInProgress: true,
        channel: .nightly,
        automationMode: .autoDownload,
        installDisposition: .installing,
        lastBlockReason: nil,
        lastInstallResultCode: .started,
        canCancelUpdate: true,
        downloadExpectedBytes: 1000,
        downloadReceivedBytes: 250,
        extractionProgress: 0.25,
        lastErrorSummary: nil,
        lastErrorDetails: nil,
        currentVersion: "1.2.0",
        availableVersion: "1.3.0",
        availableVersionTitle: "Mirage 1.3",
        releaseNotesSummary: "Maintenance release",
        releaseNotesBody: "<ul><li>Improved reliability</li></ul>",
        releaseNotesFormat: .html,
        lastCheckedAtMs: 1_700_000_000_000
    )
}
