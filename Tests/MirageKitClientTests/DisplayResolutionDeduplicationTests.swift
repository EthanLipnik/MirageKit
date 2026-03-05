//
//  DisplayResolutionDeduplicationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/3/26.
//
//  Coverage for duplicate display-resolution suppression.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

#if os(macOS)
@Suite("Display Resolution Deduplication")
struct DisplayResolutionDeduplicationTests {
    @Test("Duplicate resolution inside suppression window is skipped")
    func duplicateResolutionInsideWindowIsSuppressed() {
        let shouldSuppress = MirageClientService.shouldSuppressDuplicateDisplayResolutionChange(
            lastResolution: CGSize(width: 1944, height: 1070),
            lastRequestTime: 100,
            newResolution: CGSize(width: 1944, height: 1070),
            now: 100.1,
            suppressionWindow: 0.2
        )

        #expect(shouldSuppress)
    }

    @Test("Duplicate resolution outside suppression window is allowed")
    func duplicateResolutionOutsideWindowIsAllowed() {
        let shouldSuppress = MirageClientService.shouldSuppressDuplicateDisplayResolutionChange(
            lastResolution: CGSize(width: 1944, height: 1070),
            lastRequestTime: 100,
            newResolution: CGSize(width: 1944, height: 1070),
            now: 100.25,
            suppressionWindow: 0.2
        )

        #expect(!shouldSuppress)
    }

    @Test("Different resolution is always allowed")
    func differentResolutionIsAllowed() {
        let shouldSuppress = MirageClientService.shouldSuppressDuplicateDisplayResolutionChange(
            lastResolution: CGSize(width: 1944, height: 1070),
            lastRequestTime: 100,
            newResolution: CGSize(width: 2460, height: 1508),
            now: 100.05,
            suppressionWindow: 0.2
        )

        #expect(!shouldSuppress)
    }
}
#endif
