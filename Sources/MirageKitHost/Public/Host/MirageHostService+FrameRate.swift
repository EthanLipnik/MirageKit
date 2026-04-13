//
//  MirageHostService+FrameRate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Frame rate helpers for host-side stream setup.
//

import Foundation
import MirageKit

#if os(macOS)
extension MirageHostService {
    func initialStreamStartupFrameRate() -> Int {
        60
    }

    func resolvedTargetFrameRate(_ requested: Int) -> Int {
        max(1, min(120, requested))
    }
}
#endif
