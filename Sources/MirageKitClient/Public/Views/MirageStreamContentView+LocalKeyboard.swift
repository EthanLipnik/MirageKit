//
//  MirageStreamContentView+LocalKeyboard.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//

import Foundation
import MirageKit
import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Local Keyboard

extension MirageStreamContentView {
    #if os(iOS)
    func handleLocalKeyboardOcclusionDetectionChanged(_ isOccluded: Bool) {
        guard localKeyboardOcclusionActive != isOccluded else { return }
        localKeyboardOcclusionActive = isOccluded
    }
    #endif
}
