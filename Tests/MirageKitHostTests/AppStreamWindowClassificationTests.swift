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
}
#endif
