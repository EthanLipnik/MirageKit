//
//  LocalKeyboardOcclusionTests.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/15/26.
//

@testable import MirageKitClient
import CoreGraphics
import Testing

@Suite("Local Keyboard Occlusion")
struct LocalKeyboardOcclusionTests {
    @Test("Large keyboard overlap is treated as client-side occlusion")
    func largeKeyboardOverlapActivatesLocalOcclusion() {
        #expect(
            hasLocalKeyboardOcclusion(
                keyboardEndFrame: CGRect(x: 0, y: 512, width: 1024, height: 256),
                screenBounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
                minimumOcclusionHeight: 120
            )
        )
    }

    @Test("Small bottom bars do not trigger keyboard occlusion handling")
    func smallBottomInsetsDoNotActivateLocalOcclusion() {
        #expect(
            hasLocalKeyboardOcclusion(
                keyboardEndFrame: CGRect(x: 0, y: 704, width: 1024, height: 64),
                screenBounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
                minimumOcclusionHeight: 120
            ) == false
        )
    }

    @Test("Off-screen keyboard frames do not trigger keyboard occlusion handling")
    func offscreenKeyboardFramesDoNotActivateLocalOcclusion() {
        #expect(
            hasLocalKeyboardOcclusion(
                keyboardEndFrame: CGRect(x: 0, y: 820, width: 1024, height: 256),
                screenBounds: CGRect(x: 0, y: 0, width: 1024, height: 768),
                minimumOcclusionHeight: 120
            ) == false
        )
    }
}
