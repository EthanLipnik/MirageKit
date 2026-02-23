//
//  InputEventBinaryCodec.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/23/26.
//
//  Compact binary codec for high-rate input event control payloads.
//

import CoreGraphics
import Foundation

package enum InputEventBinaryCodec {
    package static let formatVersion: UInt8 = 1
    private static let maxStringLength = 4096

    private enum EventType: UInt8 {
        case keyDown = 0x01
        case keyUp = 0x02
        case flagsChanged = 0x03
        case mouseDown = 0x04
        case mouseUp = 0x05
        case mouseMoved = 0x06
        case mouseDragged = 0x07
        case rightMouseDown = 0x08
        case rightMouseUp = 0x09
        case rightMouseDragged = 0x0A
        case otherMouseDown = 0x0B
        case otherMouseUp = 0x0C
        case otherMouseDragged = 0x0D
        case scrollWheel = 0x0E
        case magnify = 0x0F
        case rotate = 0x10
        case windowResize = 0x11
        case relativeResize = 0x12
        case pixelResize = 0x13
        case windowFocus = 0x14
    }

    package static func serialize(_ message: InputEventMessage) throws -> Data {
        var writer = Writer()
        writer.appendUInt8(formatVersion)
        writer.appendUInt16(message.streamID)
        try encode(event: message.event, writer: &writer)
        return writer.data
    }

    package static func deserialize(_ data: Data) throws -> InputEventMessage {
        var reader = Reader(data: data)
        let version = try reader.readUInt8()
        guard version == formatVersion else {
            throw MirageError.protocolError("Unsupported input event payload version \(version)")
        }
        let streamID = try reader.readUInt16()
        let eventTypeRaw = try reader.readUInt8()
        guard let eventType = EventType(rawValue: eventTypeRaw) else {
            throw MirageError.protocolError("Unknown input event payload type \(eventTypeRaw)")
        }
        let event = try decode(eventType: eventType, reader: &reader)
        try reader.requireFinished()
        return InputEventMessage(streamID: streamID, event: event)
    }

    private static func encode(event: MirageInputEvent, writer: inout Writer) throws {
        switch event {
        case let .keyDown(keyEvent):
            writer.appendUInt8(EventType.keyDown.rawValue)
            try writer.appendKeyEvent(keyEvent)
        case let .keyUp(keyEvent):
            writer.appendUInt8(EventType.keyUp.rawValue)
            try writer.appendKeyEvent(keyEvent)
        case let .flagsChanged(flags):
            writer.appendUInt8(EventType.flagsChanged.rawValue)
            writer.appendUInt64(UInt64(truncatingIfNeeded: flags.rawValue))
        case let .mouseDown(mouseEvent):
            writer.appendUInt8(EventType.mouseDown.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .mouseUp(mouseEvent):
            writer.appendUInt8(EventType.mouseUp.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .mouseMoved(mouseEvent):
            writer.appendUInt8(EventType.mouseMoved.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .mouseDragged(mouseEvent):
            writer.appendUInt8(EventType.mouseDragged.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .rightMouseDown(mouseEvent):
            writer.appendUInt8(EventType.rightMouseDown.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .rightMouseUp(mouseEvent):
            writer.appendUInt8(EventType.rightMouseUp.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .rightMouseDragged(mouseEvent):
            writer.appendUInt8(EventType.rightMouseDragged.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .otherMouseDown(mouseEvent):
            writer.appendUInt8(EventType.otherMouseDown.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .otherMouseUp(mouseEvent):
            writer.appendUInt8(EventType.otherMouseUp.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .otherMouseDragged(mouseEvent):
            writer.appendUInt8(EventType.otherMouseDragged.rawValue)
            writer.appendMouseEvent(mouseEvent)
        case let .scrollWheel(scrollEvent):
            writer.appendUInt8(EventType.scrollWheel.rawValue)
            writer.appendScrollEvent(scrollEvent)
        case let .magnify(magnifyEvent):
            writer.appendUInt8(EventType.magnify.rawValue)
            writer.appendMagnifyEvent(magnifyEvent)
        case let .rotate(rotateEvent):
            writer.appendUInt8(EventType.rotate.rawValue)
            writer.appendRotateEvent(rotateEvent)
        case let .windowResize(resizeEvent):
            writer.appendUInt8(EventType.windowResize.rawValue)
            writer.appendResizeEvent(resizeEvent)
        case let .relativeResize(resizeEvent):
            writer.appendUInt8(EventType.relativeResize.rawValue)
            try writer.appendRelativeResizeEvent(resizeEvent)
        case let .pixelResize(resizeEvent):
            writer.appendUInt8(EventType.pixelResize.rawValue)
            try writer.appendPixelResizeEvent(resizeEvent)
        case .windowFocus:
            writer.appendUInt8(EventType.windowFocus.rawValue)
        }
    }

    private static func decode(eventType: EventType, reader: inout Reader) throws -> MirageInputEvent {
        switch eventType {
        case .keyDown:
            .keyDown(try reader.readKeyEvent())
        case .keyUp:
            .keyUp(try reader.readKeyEvent())
        case .flagsChanged:
            .flagsChanged(MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: try reader.readUInt64())))
        case .mouseDown:
            .mouseDown(try reader.readMouseEvent())
        case .mouseUp:
            .mouseUp(try reader.readMouseEvent())
        case .mouseMoved:
            .mouseMoved(try reader.readMouseEvent())
        case .mouseDragged:
            .mouseDragged(try reader.readMouseEvent())
        case .rightMouseDown:
            .rightMouseDown(try reader.readMouseEvent())
        case .rightMouseUp:
            .rightMouseUp(try reader.readMouseEvent())
        case .rightMouseDragged:
            .rightMouseDragged(try reader.readMouseEvent())
        case .otherMouseDown:
            .otherMouseDown(try reader.readMouseEvent())
        case .otherMouseUp:
            .otherMouseUp(try reader.readMouseEvent())
        case .otherMouseDragged:
            .otherMouseDragged(try reader.readMouseEvent())
        case .scrollWheel:
            .scrollWheel(try reader.readScrollEvent())
        case .magnify:
            .magnify(try reader.readMagnifyEvent())
        case .rotate:
            .rotate(try reader.readRotateEvent())
        case .windowResize:
            .windowResize(try reader.readResizeEvent())
        case .relativeResize:
            .relativeResize(try reader.readRelativeResizeEvent())
        case .pixelResize:
            .pixelResize(try reader.readPixelResizeEvent())
        case .windowFocus:
            .windowFocus
        }
    }

    private struct Writer {
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

        mutating func appendMouseEvent(_ event: MirageMouseEvent) {
            appendUInt8(UInt8(clamping: event.button.rawValue))
            appendCGPoint(event.location)
            appendUInt32(UInt32(clamping: event.clickCount))
            appendUInt64(UInt64(truncatingIfNeeded: event.modifiers.rawValue))
            appendDouble(Double(event.pressure))
            appendStylusEvent(event.stylus)
            appendDouble(event.timestamp)
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
            appendUInt8(UInt8(clamping: event.phase.rawValue))
            appendDouble(event.timestamp)
        }

        mutating func appendRotateEvent(_ event: MirageRotateEvent) {
            appendDouble(Double(event.rotation))
            appendUInt8(UInt8(clamping: event.phase.rawValue))
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

        mutating func appendFixedWidth<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { bytes in
                data.append(contentsOf: bytes)
            }
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int = 0

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else {
                throw MirageError.protocolError("Input payload truncated at offset \(offset)")
            }
            let value = data[data.index(data.startIndex, offsetBy: offset)]
            offset += 1
            return value
        }

        mutating func readUInt16() throws -> UInt16 {
            try readFixedWidth(UInt16.self)
        }

        mutating func readUInt32() throws -> UInt32 {
            try readFixedWidth(UInt32.self)
        }

        mutating func readUInt64() throws -> UInt64 {
            try readFixedWidth(UInt64.self)
        }

        mutating func readInt32() throws -> Int32 {
            try readFixedWidth(Int32.self)
        }

        mutating func readBool() throws -> Bool {
            let raw = try readUInt8()
            return raw != 0
        }

        mutating func readDouble() throws -> Double {
            Double(bitPattern: try readUInt64())
        }

        mutating func readCGPoint() throws -> CGPoint {
            CGPoint(x: CGFloat(try readDouble()), y: CGFloat(try readDouble()))
        }

        mutating func readCGSize() throws -> CGSize {
            CGSize(width: CGFloat(try readDouble()), height: CGFloat(try readDouble()))
        }

        mutating func readOptionalString() throws -> String? {
            guard try readBool() else { return nil }
            return try readString()
        }

        mutating func readString() throws -> String {
            let length = Int(try readUInt16())
            guard length <= InputEventBinaryCodec.maxStringLength else {
                throw MirageError.protocolError("Input string field exceeds \(InputEventBinaryCodec.maxStringLength) bytes")
            }
            guard offset + length <= data.count else {
                throw MirageError.protocolError("Input string field exceeds payload bounds")
            }
            let start = data.index(data.startIndex, offsetBy: offset)
            let end = data.index(start, offsetBy: length)
            let utf8 = data[start ..< end]
            offset += length
            guard let value = String(data: utf8, encoding: .utf8) else {
                throw MirageError.protocolError("Input string field is not valid UTF-8")
            }
            return value
        }

        mutating func readKeyEvent() throws -> MirageKeyEvent {
            let keyCode = try readUInt16()
            let characters = try readOptionalString()
            let charactersIgnoringModifiers = try readOptionalString()
            let modifiers = MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: try readUInt64()))
            let isRepeat = try readBool()
            let timestamp = try readDouble()
            return MirageKeyEvent(
                keyCode: keyCode,
                characters: characters,
                charactersIgnoringModifiers: charactersIgnoringModifiers,
                modifiers: modifiers,
                isRepeat: isRepeat,
                timestamp: timestamp
            )
        }

        mutating func readMouseEvent() throws -> MirageMouseEvent {
            let buttonRaw = Int(try readUInt8())
            let location = try readCGPoint()
            let clickCount = Int(try readUInt32())
            let modifiers = MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: try readUInt64()))
            let pressure = CGFloat(try readDouble())
            let stylus = try readStylusEvent()
            let timestamp = try readDouble()
            return MirageMouseEvent(
                button: MirageMouseButton(rawValue: buttonRaw) ?? .left,
                location: location,
                clickCount: clickCount,
                modifiers: modifiers,
                pressure: pressure,
                stylus: stylus,
                timestamp: timestamp
            )
        }

        mutating func readStylusEvent() throws -> MirageStylusEvent? {
            guard try readBool() else { return nil }
            let altitudeAngle = CGFloat(try readDouble())
            let azimuthAngle = CGFloat(try readDouble())
            let tiltX = CGFloat(try readDouble())
            let tiltY = CGFloat(try readDouble())
            let rollAngle: CGFloat? = try readBool() ? CGFloat(try readDouble()) : nil
            let zOffset: CGFloat? = try readBool() ? CGFloat(try readDouble()) : nil
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

        mutating func readScrollEvent() throws -> MirageScrollEvent {
            let deltaX = CGFloat(try readDouble())
            let deltaY = CGFloat(try readDouble())
            let location: CGPoint? = try readBool() ? try readCGPoint() : nil
            let phase = MirageScrollPhase(rawValue: Int(try readUInt8())) ?? .none
            let momentumPhase = MirageScrollPhase(rawValue: Int(try readUInt8())) ?? .none
            let modifiers = MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: try readUInt64()))
            let isPrecise = try readBool()
            let timestamp = try readDouble()
            return MirageScrollEvent(
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

        mutating func readMagnifyEvent() throws -> MirageMagnifyEvent {
            let magnification = CGFloat(try readDouble())
            let phase = MirageScrollPhase(rawValue: Int(try readUInt8())) ?? .none
            let timestamp = try readDouble()
            return MirageMagnifyEvent(
                magnification: magnification,
                phase: phase,
                timestamp: timestamp
            )
        }

        mutating func readRotateEvent() throws -> MirageRotateEvent {
            let rotation = CGFloat(try readDouble())
            let phase = MirageScrollPhase(rawValue: Int(try readUInt8())) ?? .none
            let timestamp = try readDouble()
            return MirageRotateEvent(
                rotation: rotation,
                phase: phase,
                timestamp: timestamp
            )
        }

        mutating func readResizeEvent() throws -> MirageResizeEvent {
            let windowID = try readUInt32()
            let newSize = try readCGSize()
            let scaleFactor = CGFloat(try readDouble())
            let timestamp = try readDouble()
            return MirageResizeEvent(
                windowID: windowID,
                newSize: newSize,
                scaleFactor: scaleFactor,
                timestamp: timestamp
            )
        }

        mutating func readRelativeResizeEvent() throws -> MirageRelativeResizeEvent {
            let windowID = try readUInt32()
            let aspectRatio = CGFloat(try readDouble())
            let relativeScale = CGFloat(try readDouble())
            let clientScreenSize = try readCGSize()
            let pixelWidth = Int(try readInt32())
            let pixelHeight = Int(try readInt32())
            let timestamp = try readDouble()
            return MirageRelativeResizeEvent(
                windowID: windowID,
                aspectRatio: aspectRatio,
                relativeScale: relativeScale,
                clientScreenSize: clientScreenSize,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                timestamp: timestamp
            )
        }

        mutating func readPixelResizeEvent() throws -> MiragePixelResizeEvent {
            let windowID = try readUInt32()
            let pixelWidth = Int(try readInt32())
            let pixelHeight = Int(try readInt32())
            let timestamp = try readDouble()
            return MiragePixelResizeEvent(
                windowID: windowID,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                timestamp: timestamp
            )
        }

        mutating func readFixedWidth<T: FixedWidthInteger>(_: T.Type) throws -> T {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else {
                throw MirageError.protocolError("Input payload truncated at offset \(offset)")
            }
            let value = data.withUnsafeBytes { ptr in
                ptr.loadUnaligned(fromByteOffset: offset, as: T.self)
            }
            offset += size
            return T(littleEndian: value)
        }

        mutating func requireFinished() throws {
            guard offset == data.count else {
                throw MirageError.protocolError("Input payload has trailing bytes (\(data.count - offset))")
            }
        }
    }
}
