//
//  LocalKeyboardOcclusionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/9/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Local Keyboard Occlusion")
struct LocalKeyboardOcclusionTests {
    @Test("Keyboard occlusion uses stream window bounds")
    func keyboardOcclusionUsesStreamWindowBounds() {
        let keyboardFrame = CGRect(x: 0, y: 700, width: 1200, height: 324)
        let streamWindowFrame = CGRect(x: 100, y: 520, width: 700, height: 320)

        let hasOcclusion = hasLocalKeyboardOcclusion(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        )

        #expect(hasOcclusion)
        #expect(localKeyboardOcclusionHeight(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        ) == 140)
    }

    @Test("Keyboard elsewhere on screen does not occlude stream window")
    func keyboardElsewhereOnScreenDoesNotOccludeStreamWindow() {
        let keyboardFrame = CGRect(x: 0, y: 700, width: 1200, height: 324)
        let streamWindowFrame = CGRect(x: 100, y: 80, width: 700, height: 360)

        let hasOcclusion = hasLocalKeyboardOcclusion(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        )

        #expect(!hasOcclusion)
        #expect(localKeyboardOcclusionHeight(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        ) == 0)
    }

    @Test("Small keyboard overlap is ignored")
    func smallKeyboardOverlapIsIgnored() {
        let keyboardFrame = CGRect(x: 0, y: 700, width: 1200, height: 324)
        let streamWindowFrame = CGRect(x: 100, y: 620, width: 700, height: 160)

        let hasOcclusion = hasLocalKeyboardOcclusion(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        )

        #expect(!hasOcclusion)
        #expect(localKeyboardOcclusionHeight(
            keyboardFrame: keyboardFrame,
            occlusionBounds: streamWindowFrame,
            minimumOcclusionHeight: 120
        ) == 0)
    }
}
