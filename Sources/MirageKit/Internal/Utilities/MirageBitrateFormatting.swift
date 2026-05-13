//
//  MirageBitrateFormatting.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/8/26.
//

import Foundation

/// Formats a bitrate for compact diagnostics and stream startup logs.
package func mirageFormattedMegabitRate(_ bitrate: Int) -> String {
    (Double(bitrate) / 1_000_000.0).formatted(.number.precision(.fractionLength(1))) + " Mbps"
}
