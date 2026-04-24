//
//  ClientDisplayGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/17/26.
//

@testable import MirageKit
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Client Display Geometry")
struct ClientDisplayGeometryTests {
    @MainActor
    @Test("Vision Pro fixed pixel budget stays inside the hard 4K encoded box")
    func visionOSFixedPixelBudgetStaysInsideHard4KEncodedBox() {
        let logicalResolution = MirageClientService.fixedPixelBudgetLogicalResolution(
            for: CGSize(width: 4126, height: 2008),
            displayScaleFactor: 2.0
        )
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: logicalResolution,
            displayScaleFactor: 2.0
        )

        #expect(geometry.displayPixelSize.width <= 3840)
        #expect(geometry.displayPixelSize.height <= 2160)
    }

    @MainActor
    @Test("Vision Pro fixed pixel budget uses Retina logical size when scale is unavailable")
    func visionOSFixedPixelBudgetUsesRetinaLogicalSizeWhenScaleIsUnavailable() {
        let logicalResolution = MirageClientService.fixedPixelBudgetLogicalResolution(
            for: CGSize(width: 3840, height: 2160),
            displayScaleFactor: 1.0
        )
        let geometry = MirageStreamGeometry.resolve(
            logicalSize: logicalResolution,
            displayScaleFactor: MirageClientService.visionOSPreferredVirtualDisplayScaleFactor
        )

        #expect(logicalResolution == CGSize(width: 1920, height: 1080))
        #expect(geometry.displayPixelSize == CGSize(width: 3840, height: 2160))
    }

    @MainActor
    @Test("Client reports active post-resize transitions until presentation settles")
    func clientReportsActivePostResizeTransitions() {
        let service = MirageClientService(deviceName: "Test Device")

        #expect(!service.hasActivePostResizeTransition)
        service.sessionStore.beginPostResizeTransition(for: 3)
        #expect(service.hasActivePostResizeTransition)
        service.sessionStore.clearPostResizeTransition(for: 3)
        #expect(!service.hasActivePostResizeTransition)
    }
}
