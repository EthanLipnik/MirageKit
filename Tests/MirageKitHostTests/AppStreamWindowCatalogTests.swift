//
//  AppStreamWindowCatalogTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitHost
import CoreGraphics
import MirageKit
import Testing

#if os(macOS)
@Suite("App Stream Window Catalog")
struct AppStreamWindowCatalogTests {
    @Test("Focused top-level utility panels are treated as primary windows")
    func focusedUtilityPanelIsPrimary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXUtilityPanel",
            parentWindowID: nil,
            isFocused: true,
            isMain: false
        )

        #expect(classification == .primary)
    }

    @Test("Unfocused utility panels remain auxiliary")
    func unfocusedUtilityPanelRemainsAuxiliary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXUtilityPanel",
            parentWindowID: nil,
            isFocused: false,
            isMain: false
        )

        #expect(classification == .auxiliary)
    }

    @Test("Child panels remain auxiliary even when focused")
    func childPanelRemainsAuxiliary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXFloatingWindow",
            parentWindowID: 42,
            isFocused: true,
            isMain: true
        )

        #expect(classification == .auxiliary)
    }

    @Test("Captured window cluster includes auxiliary descendants")
    func capturedWindowClusterIncludesAuxiliaryDescendants() {
        let primary = makeCandidate(
            windowID: 100,
            frame: CGRect(x: 40, y: 60, width: 900, height: 700)
        )
        let auxiliary = AppStreamWindowCandidate(
            bundleIdentifier: primary.bundleIdentifier,
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
            bundleIdentifier: primary.bundleIdentifier,
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
        #expect(cluster?.sourceRect == CGRect(x: 40, y: 60, width: 940, height: 700))
    }

    private func makeCandidate(
        windowID: WindowID,
        frame: CGRect
    ) -> AppStreamWindowCandidate {
        AppStreamWindowCandidate(
            bundleIdentifier: "com.example.app",
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
    ) -> MirageWindow {
        MirageWindow(
            id: id,
            title: "Window \(id)",
            application: MirageApplication(
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
