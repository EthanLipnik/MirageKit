//
//  AppStreamWindowCatalogTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

#if os(macOS)
@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing
import MirageCore
import MirageMedia

@Suite("App Stream Window Catalog")
struct AppStreamWindowCatalogTests {
    @Test("Captured window cluster includes auxiliary descendants")
    func capturedWindowClusterIncludesAuxiliaryDescendants() {
        let primary = makeCandidate(
            windowID: 100,
            frame: CGRect(x: 40, y: 60, width: 900, height: 700)
        )
        let auxiliary = AppStreamWindowCandidate(
            window: makeWindow(
                id: 101,
                frame: CGRect(x: 720, y: 80, width: 260, height: 300)
            ),
            classification: .auxiliary,
            role: "AXSheet",
            subrole: "AXSystemDialog",
            parentWindowID: primary.window.id
        )
        let nestedAuxiliary = AppStreamWindowCandidate(
            window: makeWindow(
                id: 102,
                frame: CGRect(x: 760, y: 320, width: 220, height: 180)
            ),
            classification: .auxiliary,
            role: "AXPopover",
            subrole: "AXSystemDialog",
            parentWindowID: auxiliary.window.id
        )
        let unrelatedPrimary = makeCandidate(
            windowID: 103,
            frame: CGRect(x: 1200, y: 90, width: 500, height: 500)
        )

        let cluster = AppStreamWindowCatalog.capturedWindowCluster(
            primaryWindowID: primary.window.id,
            candidates: [primary, auxiliary, nestedAuxiliary, unrelatedPrimary]
        )

        #expect(cluster?.windowIDs == [100, 101, 102])
    }

    @Test("Small visible alerts are eligible as auxiliaries below primary size")
    func smallVisibleAlertsAreEligibleAsAuxiliariesBelowPrimarySize() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXDialog",
            parentWindowID: nil
        )

        #expect(classification == .auxiliary)
        #expect(AppStreamWindowCatalog.catalogEligibility(
            classification: classification,
            frame: CGRect(x: 20, y: 20, width: 96, height: 72),
            windowLayer: 8,
            screenCaptureIsOnScreen: true,
            metadata: WindowListMetadata(alpha: 1, isOnScreen: true, orderIndex: 0),
            hasMatchingScreenCaptureWindow: true
        ))
        #expect(!AppStreamWindowCatalog.catalogEligibility(
            classification: .primary,
            frame: CGRect(x: 20, y: 20, width: 96, height: 72),
            windowLayer: 0,
            screenCaptureIsOnScreen: true,
            metadata: WindowListMetadata(alpha: 1, isOnScreen: true, orderIndex: 0),
            hasMatchingScreenCaptureWindow: true
        ))
    }

    @Test("Auxiliary cataloging rejects invisible transparent and unmatched windows")
    func auxiliaryCatalogingRejectsInvisibleTransparentAndUnmatchedWindows() {
        let frame = CGRect(x: 0, y: 0, width: 80, height: 48)

        #expect(!AppStreamWindowCatalog.catalogEligibility(
            classification: .auxiliary,
            frame: frame,
            windowLayer: 12,
            screenCaptureIsOnScreen: false,
            metadata: WindowListMetadata(alpha: 1, isOnScreen: false, orderIndex: 0),
            hasMatchingScreenCaptureWindow: true
        ))
        #expect(!AppStreamWindowCatalog.catalogEligibility(
            classification: .auxiliary,
            frame: frame,
            windowLayer: 12,
            screenCaptureIsOnScreen: true,
            metadata: WindowListMetadata(alpha: 0.02, isOnScreen: true, orderIndex: 0),
            hasMatchingScreenCaptureWindow: true
        ))
        #expect(!AppStreamWindowCatalog.catalogEligibility(
            classification: .auxiliary,
            frame: frame,
            windowLayer: 12,
            screenCaptureIsOnScreen: true,
            metadata: WindowListMetadata(alpha: 1, isOnScreen: true, orderIndex: 0),
            hasMatchingScreenCaptureWindow: false
        ))
    }

    @Test("AX sheets panels and active unknowns classify as auxiliary")
    func axSheetsPanelsAndActiveUnknownsClassifyAsAuxiliary() {
        #expect(AppStreamWindowCatalog.classifyWindow(
            role: "AXSheet",
            subrole: nil,
            parentWindowID: 100
        ) == .auxiliary)
        #expect(AppStreamWindowCatalog.classifyWindow(
            role: "AXPanel",
            subrole: "AXFloatingWindow",
            parentWindowID: nil
        ) == .auxiliary)
        #expect(AppStreamWindowCatalog.classifyWindow(
            role: "AXUnknown",
            subrole: nil,
            parentWindowID: nil,
            isModal: true
        ) == .auxiliary)
    }

    @Test("Startup selection does not allocate slots to auxiliary-only candidates")
    func startupSelectionDoesNotAllocateSlotsToAuxiliaryOnlyCandidates() {
        let auxiliary = AppStreamWindowCandidate(
            window: makeWindow(
                id: 201,
                frame: CGRect(x: 40, y: 40, width: 80, height: 48)
            ),
            classification: .auxiliary,
            role: "AXDialog",
            subrole: "AXSystemDialog",
            parentWindowID: nil,
            isFocused: true,
            isMain: true,
            isModal: true
        )

        let candidates = AppStreamWindowCatalog.startupCandidateSelection(from: [auxiliary])

        #expect(candidates.isEmpty)
    }

    private func makeCandidate(
        windowID: WindowID,
        frame: CGRect
    ) -> AppStreamWindowCandidate {
        AppStreamWindowCandidate(
            window: makeWindow(id: windowID, frame: frame),
            classification: .primary,
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil,
            isFocused: true,
            isMain: true
        )
    }

    private func makeWindow(
        id: WindowID,
        frame: CGRect
    ) -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: id,
            title: "Window \(id)",
            application: MirageMedia.MirageApplication(
                id: 1,
                bundleIdentifier: "com.example.app",
                name: "Example"
            ),
            frame: frame,
            isOnScreen: true,
            windowLayer: 0
        )
    }
}
#endif
