//
//  CursorMonitorSourceResolutionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

@testable import MirageKitHost
import AppKit
import MirageKit
import Testing

#if os(macOS)
@MainActor
@Suite("Cursor Monitor Source Resolution")
struct CursorMonitorSourceResolutionTests {
    @Test("System cursor wins over stale process cursor")
    func systemCursorWinsOverStaleProcessCursor() {
        let resolved = CursorMonitor.resolvedCursorType(
            currentSystemCursor: .closedHand,
            currentCursor: Self.unrecognizedCursor()
        )

        #expect(resolved.cursorType == .closedHand)
        #expect(resolved.source == "currentSystem")
    }

    @Test("Unrecognized system cursor falls back to process cursor")
    func unrecognizedSystemCursorFallsBackToProcessCursor() {
        let resolved = CursorMonitor.resolvedCursorType(
            currentSystemCursor: Self.unrecognizedCursor(),
            currentCursor: .closedHand
        )

        #expect(resolved.cursorType == .closedHand)
        #expect(resolved.source == "current")
    }

    @Test("Unrecognized cursor sources fall back to arrow")
    func unrecognizedCursorSourcesFallBackToArrow() {
        let resolved = CursorMonitor.resolvedCursorType(
            currentSystemCursor: Self.unrecognizedCursor(),
            currentCursor: Self.unrecognizedCursor()
        )

        #expect(resolved.cursorType == .arrow)
        #expect(resolved.source == "fallback")
    }

    private static func unrecognizedCursor() -> NSCursor {
        let image = NSImage(size: NSSize(width: 5, height: 5))
        image.lockFocus()
        NSColor(calibratedRed: 0.93, green: 0.07, blue: 0.61, alpha: 1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 5, height: 5)).fill()
        image.unlockFocus()
        return NSCursor(image: image, hotSpot: .zero)
    }
}
#endif
