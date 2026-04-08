//
//  AppStreamWindowCatalogTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/7/26.
//

@testable import MirageKitHost
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
}
#endif
