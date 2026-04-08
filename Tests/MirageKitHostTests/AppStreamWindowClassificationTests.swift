//
//  AppStreamWindowClassificationTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/26/26.
//
//  App-stream window classification policy decisions.
//

@testable import MirageKitHost
import MirageKit
import Testing

#if os(macOS)
@Suite("App Stream Window Classification")
struct AppStreamWindowClassificationTests {
    @Test("Standard window classification is primary")
    func standardWindowIsPrimary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: nil
        )

        #expect(classification == .primary)
    }

    @Test("Dialog subrole classification is auxiliary")
    func dialogSubroleIsAuxiliary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXDialog",
            parentWindowID: nil
        )

        #expect(classification == .auxiliary)
    }

    @Test("Sheet role classification is auxiliary")
    func sheetRoleIsAuxiliary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXSheet",
            subrole: nil,
            parentWindowID: nil
        )

        #expect(classification == .auxiliary)
    }

    @Test("AX parent window classification is auxiliary")
    func parentedWindowIsAuxiliary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXStandardWindow",
            parentWindowID: WindowID(77)
        )

        #expect(classification == .auxiliary)
    }

    @Test("Missing AX metadata falls back to primary")
    func missingAXMetadataFallsBackToPrimary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: nil,
            subrole: nil,
            parentWindowID: nil
        )

        #expect(classification == .primary)
    }

    @Test("Focused top-level utility panels stay eligible as primary windows")
    func focusedTopLevelUtilityPanelIsPrimary() {
        let classification = AppStreamWindowCatalog.classifyWindow(
            role: "AXWindow",
            subrole: "AXUtilityPanel",
            parentWindowID: nil,
            isFocused: true,
            isMain: true
        )

        #expect(classification == .primary)
    }

    @Test("Standalone focused auxiliary windows can be used as startup fallback candidates")
    func standaloneAuxiliaryWindowsCanFallbackToPrimarySelection() {
        let auxiliaryWindow = AppStreamWindowCandidate(
            bundleIdentifier: "com.example.test",
            window: MirageWindow(
                id: WindowID(42),
                title: "Inspector",
                application: MirageApplication(
                    id: 7,
                    bundleIdentifier: "com.example.test",
                    name: "Test App"
                ),
                frame: CGRect(x: 0, y: 0, width: 800, height: 600),
                isOnScreen: true,
                windowLayer: 0
            ),
            classification: .auxiliary,
            role: "AXWindow",
            subrole: "AXFloatingWindow",
            parentWindowID: nil,
            isFocused: true,
            isMain: false
        )
        let parentedAuxiliaryWindow = AppStreamWindowCandidate(
            bundleIdentifier: "com.example.test",
            window: MirageWindow(
                id: WindowID(43),
                title: "Sheet",
                application: MirageApplication(
                    id: 7,
                    bundleIdentifier: "com.example.test",
                    name: "Test App"
                ),
                frame: CGRect(x: 0, y: 0, width: 640, height: 480),
                isOnScreen: true,
                windowLayer: 0
            ),
            classification: .auxiliary,
            role: "AXSheet",
            subrole: nil,
            parentWindowID: WindowID(42),
            isFocused: true,
            isMain: false
        )

        let fallbackCandidates = MirageHostService.standaloneAuxiliaryFallbackCandidates(
            from: [parentedAuxiliaryWindow, auxiliaryWindow]
        )

        #expect(fallbackCandidates.map(\.window.id) == [WindowID(42)])
    }
}
#endif
