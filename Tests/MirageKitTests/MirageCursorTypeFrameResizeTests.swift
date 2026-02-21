//
//  MirageCursorTypeFrameResizeTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/20/26.
//
//  Verifies frame-resize cursor decoding for edge variants.
//

import MirageKit
import Testing

#if os(macOS)
import AppKit

@Suite("Mirage Cursor Type Frame Resize Mapping")
struct MirageCursorTypeFrameResizeTests {
    @Test("Frame edge cursors map to edge resize variants")
    func frameEdgeCursorMapping() {
        guard #available(macOS 15.0, *) else { return }

        #expect(MirageCursorType(from: NSCursor.frameResize(position: .left, directions: .inward)) == .resizeRight)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .left, directions: .outward)) == .resizeLeft)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .left, directions: .all)) == .resizeLeftRight)

        #expect(MirageCursorType(from: NSCursor.frameResize(position: .right, directions: .inward)) == .resizeLeft)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .right, directions: .outward)) == .resizeRight)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .right, directions: .all)) == .resizeLeftRight)

        #expect(MirageCursorType(from: NSCursor.frameResize(position: .top, directions: .inward)) == .resizeDown)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .top, directions: .outward)) == .resizeUp)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .top, directions: .all)) == .resizeUpDown)

        #expect(MirageCursorType(from: NSCursor.frameResize(position: .bottom, directions: .inward)) == .resizeUp)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .bottom, directions: .outward)) == .resizeDown)
        #expect(MirageCursorType(from: NSCursor.frameResize(position: .bottom, directions: .all)) == .resizeUpDown)
    }
}
#endif
