//
//  MirageMediaPacketSizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import Foundation

package let mirageDirectLocalMaxPacketSize: Int = 1400

package func miragePreferredMediaMaxPacketSize(
    for pathKind: MirageNetworkPathKind?
) -> Int {
    switch pathKind {
    case .awdl, .wired:
        return mirageDirectLocalMaxPacketSize
    default:
        return mirageDefaultMaxPacketSize
    }
}

package func mirageNegotiatedMediaMaxPacketSize(
    requested: Int?,
    pathKind: MirageNetworkPathKind?
) -> Int {
    let preferred = miragePreferredMediaMaxPacketSize(for: pathKind)
    let requestedSize = requested ?? preferred
    let clampedRequestedSize = max(
        mirageDefaultMaxPacketSize,
        min(mirageDirectLocalMaxPacketSize, requestedSize)
    )
    return min(preferred, clampedRequestedSize)
}
