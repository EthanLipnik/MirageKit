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
    func resolvedTargetFrameRate(_ requested: Int) -> Int {
        guard requested > 0 else { return 60 }
        return requested >= 120 ? 120 : 60
    }
}
#endif
