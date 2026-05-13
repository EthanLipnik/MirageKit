//
//  MirageHostService+FrameRate.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/30/26.
//
//  Frame rate helpers for host-side stream setup.
//

import MirageKit

#if os(macOS)
extension MirageHostService {
    /// Clamps a requested target frame rate to the host's supported streaming range.
    func resolvedTargetFrameRate(_ requested: Int) -> Int {
        guard requested > 0 else { return 60 }
        return min(120, requested)
    }
}
#endif
