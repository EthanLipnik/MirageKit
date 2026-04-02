//
//  MirageDesktopBitrateScaling.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/2/26.
//

import CoreGraphics
import Foundation

package enum MirageDesktopBitrateScaling {
    private static let baselineArea: Double = 2560.0 * 1440.0

    package static func scaleFactor(for displaySize: CGSize) -> Double {
        let displayArea = Double(displaySize.width) * Double(displaySize.height)
        guard displayArea > 0 else { return 1.0 }
        return min(max(displayArea / baselineArea, 1.0), 2.0)
    }

    package static func effectiveBitrate(
        enteredBitrate: Int,
        displaySize: CGSize
    ) -> Int {
        Int((Double(enteredBitrate) * scaleFactor(for: displaySize)).rounded(.down))
    }
}
