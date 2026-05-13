//
//  InputEventBinaryCodec+Writer.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import CoreGraphics
import Foundation

extension InputEventBinaryCodec {
    /// Writes high-rate input events using the current little-endian binary payload layout.
    struct Writer {
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

        mutating func appendInt32(_ value: Int) throws {
            guard let raw = Int32(exactly: value) else {
                throw MirageError.protocolError("Input payload integer overflow for Int32 field")
            }
            appendFixedWidth(raw)
        }

        mutating func appendBool(_ value: Bool) {
            appendUInt8(value ? 1 : 0)
        }

        mutating func appendDouble(_ value: Double) {
            appendFixedWidth(value.bitPattern)
        }

        mutating func appendCGPoint(_ point: CGPoint) {
            appendDouble(Double(point.x))
            appendDouble(Double(point.y))
        }

        mutating func appendCGSize(_ size: CGSize) {
            appendDouble(Double(size.width))
            appendDouble(Double(size.height))
        }

        mutating func appendOptionalString(_ value: String?) throws {
            guard let value else {
                appendBool(false)
                return
            }
            appendBool(true)
            try appendString(value)
        }

        mutating func appendString(_ value: String) throws {
            let utf8 = Data(value.utf8)
            guard utf8.count <= InputEventBinaryCodec.maxStringLength else {
                throw MirageError.protocolError("Input string field exceeds \(InputEventBinaryCodec.maxStringLength) bytes")
            }
            guard let length = UInt16(exactly: utf8.count) else {
                throw MirageError.protocolError("Input string field length overflow")
            }
            appendUInt16(length)
            data.append(utf8)
        }

        mutating func appendKeyEvent(_ event: MirageKeyEvent) throws {
            appendUInt16(event.keyCode)
            try appendOptionalString(event.characters)
            try appendOptionalString(event.charactersIgnoringModifiers)
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendBool(event.isRepeat)
            appendDouble(event.timestamp)
        }

        mutating func appendHostSystemActionRequest(_ request: MirageHostSystemActionRequest) throws {
            appendUInt8(request.action.rawValue)
            appendBool(request.fallbackKeyEvent != nil)
            if let fallbackKeyEvent = request.fallbackKeyEvent {
                try appendKeyEvent(fallbackKeyEvent)
            }
        }

        mutating func appendMouseEvent(_ event: MirageMouseEvent) {
            appendUInt8(UInt8(clamping: event.button.rawValue))
            appendCGPoint(event.location)
            appendUInt32(UInt32(clamping: event.clickCount))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendDouble(Double(event.pressure))
            appendStylusEvent(event.stylus)
            appendDouble(event.timestamp)
        }

        mutating func appendPointerSampleBatch(_ batch: MiragePointerSampleBatch) throws {
            appendUInt8(batch.phase.rawValue)
            appendUInt8(UInt8(clamping: batch.button.rawValue))
            appendUInt64(UInt64(truncatingIfNeeded: batch.modifiers.rawValue))
            appendUInt32(UInt32(clamping: batch.clickCount))
            appendBool(batch.isButtonPressed)
            appendDouble(batch.timestamp)
            guard let sampleCount = UInt16(exactly: batch.samples.count) else {
                throw MirageError.protocolError("Pointer sample batch exceeds \(UInt16.max) samples")
            }
            appendUInt16(sampleCount)
            for sample in batch.samples {
                appendPointerSample(sample)
            }
        }

        mutating func appendPointerSample(_ sample: MiragePointerSample) {
            appendCGPoint(sample.location)
            appendDouble(Double(sample.pressure))
            appendStylusEvent(sample.stylus)
            appendDouble(sample.timestamp)
        }

        mutating func appendStylusEvent(_ event: MirageStylusEvent?) {
            guard let event else {
                appendBool(false)
                return
            }
            appendBool(true)
            appendDouble(Double(event.altitudeAngle))
            appendDouble(Double(event.azimuthAngle))
            appendDouble(Double(event.tiltX))
            appendDouble(Double(event.tiltY))
            appendBool(event.rollAngle != nil)
            if let rollAngle = event.rollAngle {
                appendDouble(Double(rollAngle))
            }
            appendBool(event.zOffset != nil)
            if let zOffset = event.zOffset {
                appendDouble(Double(zOffset))
            }
            appendBool(event.isHovering)
        }

        mutating func appendScrollEvent(_ event: MirageScrollEvent) {
            appendDouble(Double(event.deltaX))
            appendDouble(Double(event.deltaY))
            appendBool(event.location != nil)
            if let location = event.location {
                appendCGPoint(location)
            }
            appendUInt8(UInt8(clamping: event.phase.rawValue))
            appendUInt8(UInt8(clamping: event.momentumPhase.rawValue))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendBool(event.isPrecise)
            appendDouble(event.timestamp)
        }

        mutating func appendMagnifyEvent(_ event: MirageMagnifyEvent) {
            appendDouble(Double(event.magnification))
            appendBool(event.location != nil)
            if let location = event.location {
                appendCGPoint(location)
            }
            appendUInt8(UInt8(clamping: event.phase.rawValue))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendDouble(event.timestamp)
        }

        mutating func appendRotateEvent(_ event: MirageRotateEvent) {
            appendDouble(Double(event.rotation))
            appendBool(event.location != nil)
            if let location = event.location {
                appendCGPoint(location)
            }
            appendUInt8(UInt8(clamping: event.phase.rawValue))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendDouble(event.timestamp)
        }

        mutating func appendSwipeEvent(_ event: MirageSwipeEvent) {
            appendDouble(Double(event.deltaX))
            appendDouble(Double(event.deltaY))
            appendBool(event.location != nil)
            if let location = event.location {
                appendCGPoint(location)
            }
            appendUInt8(UInt8(clamping: event.phase.rawValue))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendDouble(event.timestamp)
        }

        mutating func appendResizeEvent(_ event: MirageResizeEvent) {
            appendUInt32(event.windowID)
            appendCGSize(event.newSize)
            appendDouble(Double(event.scaleFactor))
            appendDouble(event.timestamp)
        }

        mutating func appendRelativeResizeEvent(_ event: MirageRelativeResizeEvent) throws {
            appendUInt32(event.windowID)
            appendDouble(Double(event.aspectRatio))
            appendDouble(Double(event.relativeScale))
            appendCGSize(event.clientScreenSize)
            try appendInt32(event.pixelWidth)
            try appendInt32(event.pixelHeight)
            appendDouble(event.timestamp)
        }

        mutating func appendPixelResizeEvent(_ event: MiragePixelResizeEvent) throws {
            appendUInt32(event.windowID)
            try appendInt32(event.pixelWidth)
            try appendInt32(event.pixelHeight)
            appendDouble(event.timestamp)
        }

        mutating func appendFixedWidth(_ value: some FixedWidthInteger) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
    }
}
