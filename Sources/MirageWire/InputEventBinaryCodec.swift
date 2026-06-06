//
//  InputEventBinaryCodec.swift
//  MirageWire
//
//  Created by Ethan Lipnik on 6/5/26.
//
//  Compact binary codec for high-rate input event control payloads.
//

import CoreGraphics
import Foundation
import MirageCore
import MirageInput

package enum InputEventBinaryCodec {
    /// Binary payload format version for high-rate input control messages.
    package static let formatVersion: UInt8 = 1
    static let maxStringLength = 4096

    private enum EventType: UInt8 {
        case keyDown = 0x01
        case keyUp = 0x02
        case flagsChanged = 0x03
        case hostSystemAction = 0x04
        case mouseDown = 0x05
        case mouseUp = 0x06
        case mouseMoved = 0x07
        case mouseDragged = 0x08
        case rightMouseDown = 0x09
        case rightMouseUp = 0x0A
        case rightMouseDragged = 0x0B
        case otherMouseDown = 0x0C
        case otherMouseUp = 0x0D
        case otherMouseDragged = 0x0E
        case scrollWheel = 0x0F
        case magnify = 0x10
        case rotate = 0x11
        case windowResize = 0x12
        case relativeResize = 0x13
        case pixelResize = 0x14
        case windowFocus = 0x15
        case pointerSampleBatch = 0x16
        case swipe = 0x17
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
            throw MirageCore.MirageError.protocolError("Unsupported input event payload version \(version)")
        }
        let streamID = try reader.readUInt16()
        let eventTypeRaw = try reader.readUInt8()
        guard let eventType = EventType(rawValue: eventTypeRaw) else {
            throw MirageCore.MirageError.protocolError("Unknown input event payload type \(eventTypeRaw)")
        }
        let event = try decode(eventType: eventType, reader: &reader)
        try reader.requireFinished()
        return InputEventMessage(streamID: streamID, event: event)
    }

    private static func encode(event: MirageInput.MirageInputEvent, writer: inout Writer) throws {
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
        case let .hostSystemAction(request):
            writer.appendUInt8(EventType.hostSystemAction.rawValue)
            try writer.appendHostSystemActionRequest(request)
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
        case let .pointerSampleBatch(batch):
            writer.appendUInt8(EventType.pointerSampleBatch.rawValue)
            try writer.appendPointerSampleBatch(batch)
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
        case let .swipe(swipeEvent):
            writer.appendUInt8(EventType.swipe.rawValue)
            writer.appendSwipeEvent(swipeEvent)
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

    private static func decode(eventType: EventType, reader: inout Reader) throws -> MirageInput.MirageInputEvent {
        switch eventType {
        case .keyDown:
            try .keyDown(reader.readKeyEvent())
        case .keyUp:
            try .keyUp(reader.readKeyEvent())
        case .flagsChanged:
            try .flagsChanged(MirageInput.MirageModifierFlags(rawValue: UInt(truncatingIfNeeded: reader.readUInt64())))
        case .hostSystemAction:
            try .hostSystemAction(reader.readHostSystemActionRequest())
        case .mouseDown:
            try .mouseDown(reader.readMouseEvent())
        case .mouseUp:
            try .mouseUp(reader.readMouseEvent())
        case .mouseMoved:
            try .mouseMoved(reader.readMouseEvent())
        case .mouseDragged:
            try .mouseDragged(reader.readMouseEvent())
        case .pointerSampleBatch:
            try .pointerSampleBatch(reader.readPointerSampleBatch())
        case .rightMouseDown:
            try .rightMouseDown(reader.readMouseEvent())
        case .rightMouseUp:
            try .rightMouseUp(reader.readMouseEvent())
        case .rightMouseDragged:
            try .rightMouseDragged(reader.readMouseEvent())
        case .otherMouseDown:
            try .otherMouseDown(reader.readMouseEvent())
        case .otherMouseUp:
            try .otherMouseUp(reader.readMouseEvent())
        case .otherMouseDragged:
            try .otherMouseDragged(reader.readMouseEvent())
        case .scrollWheel:
            try .scrollWheel(reader.readScrollEvent())
        case .magnify:
            try .magnify(reader.readMagnifyEvent())
        case .rotate:
            try .rotate(reader.readRotateEvent())
        case .swipe:
            try .swipe(reader.readSwipeEvent())
        case .windowResize:
            try .windowResize(reader.readResizeEvent())
        case .relativeResize:
            try .relativeResize(reader.readRelativeResizeEvent())
        case .pixelResize:
            try .pixelResize(reader.readPixelResizeEvent())
        case .windowFocus:
            .windowFocus
        }
    }
}
