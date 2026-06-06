//
//  MirageContinuousInputBatch+Codec.swift
//  MirageInput
//
//  Created by Ethan Lipnik on 5/17/26.
//

import CoreGraphics
import Foundation
import MirageCore

package extension MirageContinuousInputBatch {
    static let wireVersion: UInt8 = 1

    func serialize() throws -> Data {
        guard samples.count <= UInt16.max else {
            throw MirageCore.MirageError.protocolError("Continuous input batch exceeds \(UInt16.max) samples")
        }

        var writer = ContinuousInputWriter()
        writer.appendUInt8(Self.wireVersion)
        writer.appendUInt16(streamID)
        writer.appendUInt64(sequence)
        writer.appendUInt8(kind.rawValue)
        writer.appendUInt8(pointerPhase?.rawValue ?? UInt8.max)
        writer.appendUInt8(UInt8(clamping: scrollPhase.rawValue))
        writer.appendUInt8(UInt8(clamping: momentumPhase.rawValue))
        writer.appendUInt8(UInt8(clamping: button.rawValue))
        writer.appendUInt64(UInt64(truncatingIfNeeded: modifiers.rawValue))
        writer.appendUInt32(UInt32(clamping: clickCount))
        writer.appendBool(isButtonPressed)
        writer.appendBool(isPrecise)
        writer.appendDouble(baseTimestamp)
        writer.appendUInt16(UInt16(samples.count))
        for sample in samples {
            writer.appendInt32(Self.timestampOffsetMicros(sample.timestamp, baseTimestamp: baseTimestamp))
            writer.appendBool(sample.location != nil)
            if let location = sample.location {
                writer.appendFixedPoint(location.x)
                writer.appendFixedPoint(location.y)
            }
            writer.appendFixedPoint(sample.valueX)
            writer.appendFixedPoint(sample.valueY)
            writer.appendUInt16(Self.encodedPressure(sample.pressure))
            writer.appendStylus(sample.stylus)
        }
        return writer.data
    }

    static func deserialize(_ data: Data) throws -> MirageContinuousInputBatch {
        var reader = ContinuousInputReader(data: data)
        let version = try reader.readUInt8()
        guard version == Self.wireVersion else {
            throw MirageCore.MirageError.protocolError("Unsupported continuous input batch version \(version)")
        }

        let streamID = try reader.readUInt16()
        let sequence = try reader.readUInt64()
        guard let kind = Kind(rawValue: try reader.readUInt8()) else {
            throw MirageCore.MirageError.protocolError("Invalid continuous input kind")
        }
        let pointerPhaseRaw = try reader.readUInt8()
        let pointerPhase = pointerPhaseRaw == UInt8.max
            ? nil
            : MiragePointerSampleBatchPhase(rawValue: pointerPhaseRaw)
        guard pointerPhaseRaw == UInt8.max || pointerPhase != nil else {
            throw MirageCore.MirageError.protocolError("Invalid continuous pointer phase")
        }
        let scrollPhaseRaw = try reader.readUInt8()
        let scrollPhase = MirageScrollPhase(rawValue: Int(scrollPhaseRaw)) ?? .none
        let momentumPhaseRaw = try reader.readUInt8()
        let momentumPhase = MirageScrollPhase(rawValue: Int(momentumPhaseRaw)) ?? .none
        let button = MirageMouseButton(buttonNumber: Int(try reader.readUInt8()))
        let modifiers = try MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: reader.readUInt64()))
        let clickCount = Int(try reader.readUInt32())
        let isButtonPressed = try reader.readBool()
        let isPrecise = try reader.readBool()
        let baseTimestamp = try reader.readDouble()
        let sampleCount = Int(try reader.readUInt16())
        var samples: [Sample] = []
        samples.reserveCapacity(sampleCount)

        for _ in 0 ..< sampleCount {
            let timestamp = baseTimestamp + (Double(try reader.readInt32()) / 1_000_000)
            let hasLocation = try reader.readBool()
            let location: CGPoint?
            if hasLocation {
                location = CGPoint(
                    x: CGFloat(try reader.readFixedPoint()),
                    y: CGFloat(try reader.readFixedPoint())
                )
            } else {
                location = nil
            }
            let valueX = CGFloat(try reader.readFixedPoint())
            let valueY = CGFloat(try reader.readFixedPoint())
            let pressure = CGFloat(Double(try reader.readUInt16()) / Double(UInt16.max))
            let stylus = try reader.readStylus()
            samples.append(Sample(
                timestamp: timestamp,
                location: location,
                valueX: valueX,
                valueY: valueY,
                pressure: pressure,
                stylus: stylus
            ))
        }
        try reader.requireFinished()

        return MirageContinuousInputBatch(
            streamID: streamID,
            sequence: sequence,
            kind: kind,
            pointerPhase: pointerPhase,
            scrollPhase: scrollPhase,
            momentumPhase: momentumPhase,
            button: button,
            modifiers: modifiers,
            clickCount: clickCount,
            isButtonPressed: isButtonPressed,
            isPrecise: isPrecise,
            samples: samples
        )
    }

    private static func timestampOffsetMicros(
        _ timestamp: TimeInterval,
        baseTimestamp: TimeInterval
    ) -> Int32 {
        let scaled = ((timestamp - baseTimestamp) * 1_000_000).rounded()
        return clampedInt32(scaled)
    }

    private static func encodedPressure(_ pressure: CGFloat) -> UInt16 {
        let clamped = min(max(Double(pressure), 0), 1)
        return UInt16(clamping: Int((clamped * Double(UInt16.max)).rounded()))
    }
}

private struct ContinuousInputWriter {
    private static let fixedPointScale = 1_000_000.0
    var data = Data()

    mutating func appendUInt8(_ value: UInt8) {
        data.append(value)
    }

    mutating func appendUInt16(_ value: UInt16) {
        appendFixedWidth(value)
    }

    mutating func appendUInt32(_ value: UInt32) {
        appendFixedWidth(value)
    }

    mutating func appendUInt64(_ value: UInt64) {
        appendFixedWidth(value)
    }

    mutating func appendInt32(_ value: Int32) {
        appendFixedWidth(value)
    }

    mutating func appendBool(_ value: Bool) {
        appendUInt8(value ? 1 : 0)
    }

    mutating func appendDouble(_ value: Double) {
        appendUInt64(value.bitPattern)
    }

    mutating func appendFixedPoint(_ value: CGFloat) {
        appendInt32(clampedInt32((Double(value) * Self.fixedPointScale).rounded()))
    }

    mutating func appendStylus(_ stylus: MirageStylusEvent?) {
        guard let stylus else {
            appendBool(false)
            return
        }
        appendBool(true)
        appendFixedPoint(stylus.altitudeAngle)
        appendFixedPoint(stylus.azimuthAngle)
        appendFixedPoint(stylus.tiltX)
        appendFixedPoint(stylus.tiltY)
        appendBool(stylus.rollAngle != nil)
        if let rollAngle = stylus.rollAngle {
            appendFixedPoint(rollAngle)
        }
        appendBool(stylus.zOffset != nil)
        if let zOffset = stylus.zOffset {
            appendFixedPoint(zOffset)
        }
        appendBool(stylus.isHovering)
    }

    private mutating func appendFixedWidth(_ value: some FixedWidthInteger) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}

private struct ContinuousInputReader {
    private static let fixedPointScale = 1_000_000.0
    private let data: Data
    private var offset = 0

    init(data: Data) {
        self.data = data
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else {
            throw MirageCore.MirageError.protocolError("Continuous input payload ended unexpectedly")
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        try readFixedWidth()
    }

    mutating func readUInt32() throws -> UInt32 {
        try readFixedWidth()
    }

    mutating func readUInt64() throws -> UInt64 {
        try readFixedWidth()
    }

    mutating func readInt32() throws -> Int32 {
        try readFixedWidth()
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readDouble() throws -> Double {
        try Double(bitPattern: readUInt64())
    }

    mutating func readFixedPoint() throws -> Double {
        Double(try readInt32()) / Self.fixedPointScale
    }

    mutating func readStylus() throws -> MirageStylusEvent? {
        guard try readBool() else { return nil }
        let altitudeAngle = CGFloat(try readFixedPoint())
        let azimuthAngle = CGFloat(try readFixedPoint())
        let tiltX = CGFloat(try readFixedPoint())
        let tiltY = CGFloat(try readFixedPoint())
        let rollAngle = try readBool() ? CGFloat(try readFixedPoint()) : nil
        let zOffset = try readBool() ? CGFloat(try readFixedPoint()) : nil
        let isHovering = try readBool()
        return MirageStylusEvent(
            altitudeAngle: altitudeAngle,
            azimuthAngle: azimuthAngle,
            tiltX: tiltX,
            tiltY: tiltY,
            rollAngle: rollAngle,
            zOffset: zOffset,
            isHovering: isHovering
        )
    }

    mutating func requireFinished() throws {
        guard offset == data.count else {
            throw MirageCore.MirageError.protocolError("Continuous input payload has trailing bytes")
        }
    }

    private mutating func readFixedWidth<T: FixedWidthInteger>() throws -> T {
        let width = MemoryLayout<T>.size
        guard offset + width <= data.count else {
            throw MirageCore.MirageError.protocolError("Continuous input payload ended unexpectedly")
        }
        let value = data.withUnsafeBytes { pointer in
            pointer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        offset += width
        return T(littleEndian: value)
    }
}

private func clampedInt32(_ value: Double) -> Int32 {
    guard value.isFinite else { return 0 }
    if value > Double(Int32.max) { return Int32.max }
    if value < Double(Int32.min) { return Int32.min }
    return Int32(value)
}
