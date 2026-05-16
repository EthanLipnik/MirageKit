//
//  MessageTypes+PriorityInput.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/15/26.
//

import Foundation

package enum MiragePriorityInputEnvelopeKind: UInt8, Sendable {
    case input = 1
    case ack = 2
}

package enum MiragePriorityInputDeliveryClass: UInt8, Sendable {
    case realtime = 1
    case protected = 2
}

package struct MiragePriorityInputEnvelope: Equatable, Sendable {
    package static let version: UInt8 = 1

    package let kind: MiragePriorityInputEnvelopeKind
    package let eventID: UInt64
    package let streamID: StreamID
    package let deliveryClass: MiragePriorityInputDeliveryClass
    package let sentAtUptime: CFAbsoluteTime
    package let inputPayload: Data

    package init(
        kind: MiragePriorityInputEnvelopeKind,
        eventID: UInt64,
        streamID: StreamID,
        deliveryClass: MiragePriorityInputDeliveryClass,
        sentAtUptime: CFAbsoluteTime,
        inputPayload: Data = Data()
    ) {
        self.kind = kind
        self.eventID = eventID
        self.streamID = streamID
        self.deliveryClass = deliveryClass
        self.sentAtUptime = sentAtUptime
        self.inputPayload = inputPayload
    }

    package func serialize() throws -> Data {
        guard inputPayload.count <= LoomMessageLimits.maxPayloadBytes else {
            throw MirageError.protocolError("Priority input payload exceeds \(LoomMessageLimits.maxPayloadBytes) bytes.")
        }

        var data = Data()
        data.reserveCapacity(25 + inputPayload.count)
        data.append(Self.version)
        data.append(kind.rawValue)
        data.append(deliveryClass.rawValue)
        Self.appendUInt64(eventID, to: &data)
        Self.appendUInt16(streamID, to: &data)
        Self.appendUInt64(sentAtUptime.bitPattern, to: &data)
        Self.appendUInt32(UInt32(inputPayload.count), to: &data)
        data.append(inputPayload)
        return data
    }

    package static func deserialize(_ data: Data) throws -> MiragePriorityInputEnvelope {
        var reader = Reader(data: data)
        let version = try reader.readUInt8()
        guard version == Self.version else {
            throw MirageError.protocolError("Unsupported priority input envelope version \(version).")
        }
        guard let kind = MiragePriorityInputEnvelopeKind(rawValue: try reader.readUInt8()) else {
            throw MirageError.protocolError("Invalid priority input envelope kind.")
        }
        guard let deliveryClass = MiragePriorityInputDeliveryClass(rawValue: try reader.readUInt8()) else {
            throw MirageError.protocolError("Invalid priority input delivery class.")
        }
        let eventID = try reader.readUInt64()
        let streamID = try reader.readUInt16()
        let sentAtUptime = CFAbsoluteTime(bitPattern: try reader.readUInt64())
        let payloadLength = Int(try reader.readUInt32())
        let inputPayload = try reader.readData(count: payloadLength)
        guard reader.isAtEnd else {
            throw MirageError.protocolError("Priority input envelope has trailing bytes.")
        }
        return MiragePriorityInputEnvelope(
            kind: kind,
            eventID: eventID,
            streamID: streamID,
            deliveryClass: deliveryClass,
            sentAtUptime: sentAtUptime,
            inputPayload: inputPayload
        )
    }

    package func inputControlMessage() throws -> ControlMessage {
        guard kind == .input else {
            throw MirageError.protocolError("Priority input envelope does not carry input.")
        }
        return ControlMessage(type: .inputEvent, payload: inputPayload)
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

private struct Reader {
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset == data.count
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw MirageError.protocolError("Truncated priority input envelope.") }
        defer { offset += 1 }
        return data[data.index(data.startIndex, offsetBy: offset)]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readInteger(UInt16.self)
    }

    mutating func readUInt32() throws -> UInt32 {
        try readInteger(UInt32.self)
    }

    mutating func readUInt64() throws -> UInt64 {
        try readInteger(UInt64.self)
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw MirageError.protocolError("Truncated priority input envelope payload.")
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: count)
        offset += count
        return Data(data[start ..< end])
    }

    private mutating func readInteger<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let byteCount = MemoryLayout<T>.size
        guard offset + byteCount <= data.count else {
            throw MirageError.protocolError("Truncated priority input envelope integer.")
        }
        let start = data.index(data.startIndex, offsetBy: offset)
        let end = data.index(start, offsetBy: byteCount)
        offset += byteCount
        return data[start ..< end].withUnsafeBytes { pointer in
            T(littleEndian: pointer.loadUnaligned(as: T.self))
        }
    }
}
