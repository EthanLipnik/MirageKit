//
//  DesktopPresentationGeometryTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

#if os(macOS)
@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Desktop Presentation Geometry")
struct DesktopPresentationGeometryTests {
    @Test("Absolute mouse normalization clamps through the desktop content rect")
    func absoluteMouseNormalizationClampsThroughDesktopContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: bounds
        )

        let normalized = ScrollPhysicsCapturingNSView.normalizedLocation(
            CGPoint(x: 20, y: 450),
            in: bounds,
            contentRect: contentRect
        )

        #expect(normalized == CGPoint(x: 0, y: 0.5))
    }

    @Test("Mirrored cursor positions map through the desktop content rect")
    func mirroredCursorPositionsMapThroughDesktopContentRect() {
        let bounds = CGRect(x: 0, y: 0, width: 1600, height: 900)
        let contentRect = DesktopPresentationGeometry.resolvedContentRect(
            referenceSize: CGSize(width: 1280, height: 800),
            in: bounds
        )

        let localPoint = ScrollPhysicsCapturingNSView.localPoint(
            forNormalizedCursorPosition: CGPoint(x: 0.25, y: 0.75),
            in: bounds,
            contentRect: contentRect
        )

        #expect(localPoint == CGPoint(x: 440, y: 225))
    }

    @Test("Unified desktop resize reports stream view bounds")
    func unifiedDesktopResizeReportsStreamViewBounds() {
        let boundsSize = CGSize(width: 1234, height: 710)
        let contentLayoutSize = CGSize(width: 1234, height: 678)

        let reportedSize = MirageStreamPresentationPolicy.containerSize(
            boundsSize: boundsSize,
            contentLayoutSize: contentLayoutSize,
            mode: .viewBounds
        )

        #expect(reportedSize == boundsSize)
    }

    @Test("Content-layout sizing remains available for non-unified contexts")
    func contentLayoutSizingRemainsAvailable() {
        let boundsSize = CGSize(width: 1234, height: 710)
        let contentLayoutSize = CGSize(width: 1234, height: 678)

        let reportedSize = MirageStreamPresentationPolicy.containerSize(
            boundsSize: boundsSize,
            contentLayoutSize: contentLayoutSize,
            mode: .contentLayout
        )

        #expect(reportedSize == contentLayoutSize)
    }

    @Test("Host display size only creates presentation reference for aspect fit")
    func hostDisplaySizeOnlyCreatesPresentationReferenceForAspectFit() {
        let hostDisplaySize = CGSize(width: 1224, height: 672)

        let fillReference = MirageStreamPresentationPolicy.localAspectFitReferenceSize(
            prefersLocalAspectFitPresentation: false,
            hostDisplayPointSize: hostDisplaySize
        )
        let aspectFitReference = MirageStreamPresentationPolicy.localAspectFitReferenceSize(
            prefersLocalAspectFitPresentation: true,
            hostDisplayPointSize: hostDisplaySize
        )

        #expect(fillReference == nil)
        #expect(aspectFitReference == hostDisplaySize)
    }

    @Test("No keyboard allows window-driven resize without local aspect fit")
    func noKeyboardAllowsResizeWithoutLocalAspectFit() {
        let suppressesResize = MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: false
        )
        let prefersAspectFit = MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation(
            localPresentationPauseActive: false,
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: false,
            appStreamPrefersAspectFitPresentation: false
        )

        #expect(!suppressesResize)
        #expect(!prefersAspectFit)
    }

    @Test("Keyboard avoidance suppresses resize and uses local aspect fit")
    func keyboardAvoidanceSuppressesResizeAndUsesLocalAspectFit() {
        let suppressesResize = MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: true,
            localKeyboardOcclusionActive: false
        )
        let prefersAspectFit = MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation(
            localPresentationPauseActive: false,
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: true,
            localKeyboardOcclusionActive: false,
            appStreamPrefersAspectFitPresentation: false
        )

        #expect(suppressesResize)
        #expect(prefersAspectFit)
    }

    @Test("Keyboard overlay allows resize without local aspect fit")
    func keyboardOverlayAllowsResizeWithoutLocalAspectFit() {
        let suppressesResize = MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: false,
            softwareKeyboardVisible: true,
            localKeyboardOcclusionActive: false
        )
        let prefersAspectFit = MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation(
            localPresentationPauseActive: false,
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: false,
            softwareKeyboardVisible: true,
            localKeyboardOcclusionActive: false,
            appStreamPrefersAspectFitPresentation: false
        )

        #expect(!suppressesResize)
        #expect(!prefersAspectFit)
    }

    @Test("Keyboard frame occlusion follows keyboard avoidance setting")
    func keyboardFrameOcclusionFollowsKeyboardAvoidanceSetting() {
        let avoidsSuppressesResize = MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: true
        )
        let overlaySuppressesResize = MirageStreamPresentationPolicy.suppressesWindowDrivenResizeForLocalPresentation(
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: false,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: true
        )
        let avoidsWithAspectFit = MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation(
            localPresentationPauseActive: false,
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: true,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: true,
            appStreamPrefersAspectFitPresentation: false
        )
        let overlaysWithoutAspectFit = MirageStreamPresentationPolicy.prefersLocalAspectFitPresentation(
            localPresentationPauseActive: false,
            isDesktopStream: false,
            useHostResolution: false,
            desktopCaptureSource: .virtualDisplay,
            desktopStreamAllowsClientResize: true,
            keyboardAvoidanceEnabled: false,
            softwareKeyboardVisible: false,
            localKeyboardOcclusionActive: true,
            appStreamPrefersAspectFitPresentation: false
        )

        #expect(avoidsSuppressesResize)
        #expect(!overlaySuppressesResize)
        #expect(avoidsWithAspectFit)
        #expect(!overlaysWithoutAspectFit)
    }
}
#endif
