//
//  InputEventBinaryCodec+Reader.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageInput

extension InputEventBinaryCodec {
    /// Reads high-rate input events from the current little-endian binary payload layout.
    struct Reader {
        let data: Data
        var offset: Int = 0

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else {
                throw MirageCore.MirageError.protocolError("Input payload truncated at offset \(offset)")
            }
            let value = data[data.index(data.startIndex, offsetBy: offset)]
            offset += 1
            return value
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
            let raw = try readUInt8()
            return raw != 0
        }

        mutating func readDouble() throws -> Double {
            try Double(bitPattern: readUInt64())
        }

        mutating func readCGPoint() throws -> CGPoint {
            try CGPoint(x: CGFloat(readDouble()), y: CGFloat(readDouble()))
        }

        mutating func readCGSize() throws -> CGSize {
            try CGSize(width: CGFloat(readDouble()), height: CGFloat(readDouble()))
        }

        mutating func readOptionalString() throws -> String? {
            guard try readBool() else { return nil }
            return try readString()
        }

        mutating func readString() throws -> String {
            let length = try Int(readUInt16())
            guard length <= InputEventBinaryCodec.maxStringLength else {
                throw MirageCore.MirageError.protocolError("Input string field exceeds \(InputEventBinaryCodec.maxStringLength) bytes")
            }
            guard offset + length <= data.count else {
                throw MirageCore.MirageError.protocolError("Input string field exceeds payload bounds")
            }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: length)
            let utf8 = data[start ..< end]
            offset += length
            guard let value = String(data: utf8, encoding: .utf8) else {
                throw MirageCore.MirageError.protocolError("Input string field is not valid UTF-8")
            }
            return value
        }

        mutating func readKeyEvent() throws -> MirageInput.MirageKeyEvent {
            let keyCode = try readUInt16()
            let characters = try readOptionalString()
            let charactersIgnoringModifiers = try readOptionalString()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let isRepeat = try readBool()
            let timestamp = try readDouble()
            return MirageInput.MirageKeyEvent(
                keyCode: keyCode,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers,
                isRepeat: isRepeat,
                timestamp: timestamp
            )
        }

        mutating func readHostSystemActionRequest() throws -> MirageInput.MirageHostSystemActionRequest {
            let actionRawValue = try readUInt8()
            guard let action = MirageInput.MirageHostSystemAction(rawValue: actionRawValue) else {
                throw MirageCore.MirageError.protocolError("Unknown host system action \(actionRawValue)")
            }
            let fallbackKeyEvent: MirageInput.MirageKeyEvent? = try readBool() ? try readKeyEvent() : nil
            return MirageInput.MirageHostSystemActionRequest(
                action: action,
                fallbackKeyEvent: fallbackKeyEvent
            )
        }

        mutating func readMouseButton() throws -> MirageInput.MirageMouseButton {
            let rawValue = try Int(readUInt8())
            guard let button = MirageInput.MirageMouseButton(rawValue: rawValue) else {
                throw MirageCore.MirageError.protocolError("Unknown mouse button \(rawValue)")
            }
            return button
        }

        mutating func readScrollPhase() throws -> MirageInput.MirageScrollPhase {
            let rawValue = try Int(readUInt8())
            guard let phase = MirageInput.MirageScrollPhase(rawValue: rawValue) else {
                throw MirageCore.MirageError.protocolError("Unknown scroll phase \(rawValue)")
            }
            return phase
        }

        mutating func readMouseEvent() throws -> MirageInput.MirageMouseEvent {
            let button = try readMouseButton()
            let location = try readCGPoint()
            let clickCount = try Int(readUInt32())
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let pressure = try CGFloat(readDouble())
            let stylus = try readStylusEvent()
            let timestamp = try readDouble()
            return MirageInput.MirageMouseEvent(
                button: button,
                location: location,
                clickCount: clickCount,
                modifiers: modifiers,
                pressure: pressure,
                stylus: stylus,
                timestamp: timestamp
            )
        }

        mutating func readPointerSampleBatch() throws -> MirageInput.MiragePointerSampleBatch {
            let phaseRaw = try readUInt8()
            guard let phase = MirageInput.MiragePointerSampleBatchPhase(rawValue: phaseRaw) else {
                throw MirageCore.MirageError.protocolError("Unknown pointer sample batch phase \(phaseRaw)")
            }
            let button = try readMouseButton()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let clickCount = try Int(readUInt32())
            let isButtonPressed = try readBool()
            let timestamp = try readDouble()
            let sampleCount = try Int(readUInt16())
            var samples: [MirageInput.MiragePointerSample] = []
            samples.reserveCapacity(sampleCount)
            for _ in 0 ..< sampleCount {
                try samples.append(readPointerSample())
            }
            return MirageInput.MiragePointerSampleBatch(
                phase: phase,
                button: button,
                modifiers: modifiers,
                clickCount: clickCount,
                isButtonPressed: isButtonPressed,
                samples: samples,
                timestamp: timestamp
            )
        }

        mutating func readPointerSample() throws -> MirageInput.MiragePointerSample {
            let location = try readCGPoint()
            let pressure = try CGFloat(readDouble())
            guard let stylus = try readStylusEvent() else {
                throw MirageCore.MirageError.protocolError("Pointer sample is missing stylus metadata")
            }
            let timestamp = try readDouble()
            return MirageInput.MiragePointerSample(
                location: location,
                pressure: pressure,
                stylus: stylus,
                timestamp: timestamp
            )
        }

        mutating func readStylusEvent() throws -> MirageInput.MirageStylusEvent? {
            guard try readBool() else { return nil }
            let altitudeAngle = try CGFloat(readDouble())
            let azimuthAngle = try CGFloat(readDouble())
            let tiltX = try CGFloat(readDouble())
            let tiltY = try CGFloat(readDouble())
            let rollAngle: CGFloat? = try readBool() ? CGFloat(readDouble()) : nil
            let zOffset: CGFloat? = try readBool() ? CGFloat(readDouble()) : nil
            let isHovering = try readBool()
            return MirageInput.MirageStylusEvent(
                altitudeAngle: altitudeAngle,
                azimuthAngle: azimuthAngle,
                tiltX: tiltX,
                tiltY: tiltY,
                rollAngle: rollAngle,
                zOffset: zOffset,
                isHovering: isHovering
            )
        }

        mutating func readScrollEvent() throws -> MirageInput.MirageScrollEvent {
            let deltaX = try CGFloat(readDouble())
            let deltaY = try CGFloat(readDouble())
            let location: CGPoint? = try readBool() ? try readCGPoint() : nil
            let phase = try readScrollPhase()
            let momentumPhase = try readScrollPhase()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let isPrecise = try readBool()
            let timestamp = try readDouble()
            return MirageInput.MirageScrollEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: location,
                phase: phase,
                momentumPhase: momentumPhase,
                modifiers: modifiers,
                isPrecise: isPrecise,
                timestamp: timestamp
            )
        }

        mutating func readMagnifyEvent() throws -> MirageInput.MirageMagnifyEvent {
            let magnification = try CGFloat(readDouble())
            let location: CGPoint? = try readBool() ? try readCGPoint() : nil
            let phase = try readScrollPhase()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let timestamp = try readDouble()
            return MirageInput.MirageMagnifyEvent(
                magnification: magnification,
                location: location,
                phase: phase,
                modifiers: modifiers,
                timestamp: timestamp
            )
        }

        mutating func readRotateEvent() throws -> MirageInput.MirageRotateEvent {
            let rotation = try CGFloat(readDouble())
            let location: CGPoint? = try readBool() ? try readCGPoint() : nil
            let phase = try readScrollPhase()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let timestamp = try readDouble()
            return MirageInput.MirageRotateEvent(
                rotation: rotation,
                location: location,
                phase: phase,
                modifiers: modifiers,
                timestamp: timestamp
            )
        }

        mutating func readSwipeEvent() throws -> MirageInput.MirageSwipeEvent {
            let deltaX = try CGFloat(readDouble())
            let deltaY = try CGFloat(readDouble())
            let location: CGPoint? = try readBool() ? try readCGPoint() : nil
            let phase = try readScrollPhase()
            let modifiers = try MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: readUInt64()))
            let timestamp = try readDouble()
            return MirageInput.MirageSwipeEvent(
                deltaX: deltaX,
                deltaY: deltaY,
                location: location,
                phase: phase,
                modifiers: modifiers,
                timestamp: timestamp
            )
        }

        mutating func readResizeEvent() throws -> MirageInput.MirageResizeEvent {
            let windowID = try readUInt32()
            let newSize = try readCGSize()
            let scaleFactor = try CGFloat(readDouble())
            let timestamp = try readDouble()
            return MirageInput.MirageResizeEvent(
                windowID: windowID,
                newSize: newSize,
                scaleFactor: scaleFactor,
                timestamp: timestamp
            )
        }

        mutating func readRelativeResizeEvent() throws -> MirageInput.MirageRelativeResizeEvent {
            let windowID = try readUInt32()
            let aspectRatio = try CGFloat(readDouble())
            let relativeScale = try CGFloat(readDouble())
            let clientScreenSize = try readCGSize()
            let pixelWidth = try Int(readInt32())
            let pixelHeight = try Int(readInt32())
            let timestamp = try readDouble()
            return MirageInput.MirageRelativeResizeEvent(
                windowID: windowID,
                aspectRatio: aspectRatio,
                relativeScale: relativeScale,
                clientScreenSize: clientScreenSize,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                timestamp: timestamp
            )
        }

        mutating func readPixelResizeEvent() throws -> MirageInput.MiragePixelResizeEvent {
            let windowID = try readUInt32()
            let pixelWidth = try Int(readInt32())
            let pixelHeight = try Int(readInt32())
            let timestamp = try readDouble()
            return MirageInput.MiragePixelResizeEvent(
                windowID: windowID,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                timestamp: timestamp
            )
        }

        mutating func readFixedWidth<T: FixedWidthInteger>() throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else {
                throw MirageCore.MirageError.protocolError("Input payload truncated at offset \(offset)")
            }
            let value = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func requireFinished() throws {
            guard offset == data.count else {
                throw MirageCore.MirageError.protocolError("Input payload has trailing bytes (\(data.count - offset))")
            }
        }
    }
}
