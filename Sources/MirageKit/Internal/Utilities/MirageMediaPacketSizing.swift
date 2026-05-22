//
//  MirageMediaPacketSizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import Foundation

package let mirageDirectLocalMaxPacketSize: Int = 1400
package let mirageDirectWiFiMaxPacketSize: Int = 1320
package let mirageDirectProximityMaxPacketSize: Int = 1200

package func miragePreferredMediaMaxPacketSize(
    for pathKind: MirageNetworkPathKind?
) -> Int {
    switch pathKind {
    case .wired:
        return mirageDirectLocalMaxPacketSize
    case .awdl:
        return mirageDirectProximityMaxPacketSize
    case .wifi:
        return mirageDirectWiFiMaxPacketSize
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
