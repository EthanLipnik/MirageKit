//
//  DesktopCursorCaptureVisibilityTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import MirageKit
@testable import MirageKitHost
import Testing

@Suite("Desktop Cursor Capture Visibility")
struct DesktopCursorCaptureVisibilityTests {
    @Test("Stream context stores cursor capture visibility at desktop start")
    func streamContextStoresInitialCaptureCursorVisibility() async {
        let context = StreamContext(
            streamID: 7,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: MirageEncoderConfiguration(),
            captureShowsCursor: true
        )

        #expect(await context.captureShowsCursor)
    }

    @Test("Stream context runtime cursor visibility update mutates stored capture state")
    func streamContextUpdatesStoredCaptureCursorVisibility() async throws {
        let context = StreamContext(
            streamID: 8,
            windowID: 0,
            streamKind: .desktop,
            encoderConfig: MirageEncoderConfiguration(),
            captureShowsCursor: false
        )

        try await context.updateCaptureShowsCursor(true)
        #expect(await context.captureShowsCursor)

        try await context.updateCaptureShowsCursor(false)
        #expect(await context.captureShowsCursor == false)
    }
}
