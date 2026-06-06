//
//  MirageMediaPacketSizing.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/31/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation

package let mirageDirectLocalMaxPacketSize: Int = 1400
package let mirageDirectWiFiMaxPacketSize: Int = 1320
package let mirageDirectProximityMaxPacketSize: Int = 1120

package func miragePreferredMediaMaxPacketSize(
    for pathKind: MirageCore.MirageNetworkPathKind?
) -> Int {
    switch pathKind {
    case .wired:
        return mirageDirectLocalMaxPacketSize
    case .awdl:
        return mirageDirectProximityMaxPacketSize
    case .wifi:
        return mirageDirectWiFiMaxPacketSize
    default:
        return MirageWire.mirageDefaultMaxPacketSize
    }
}

package func miragePreferredMediaMaxPacketSize(
    for mediaPathProfile: MirageMedia.MirageMediaPathProfile?,
    pathKind: MirageCore.MirageNetworkPathKind?
) -> Int {
    switch mediaPathProfile {
    case .awdlRadio:
        return mirageDirectProximityMaxPacketSize
    case .proximityWiredLike, .wired:
        return mirageDirectLocalMaxPacketSize
    case .localWiFi:
        return mirageDirectWiFiMaxPacketSize
    case .vpnOrOverlay, .other, .unknown, nil:
        return miragePreferredMediaMaxPacketSize(for: pathKind)
    }
}

package func mirageNegotiatedMediaMaxPacketSize(
    requested: Int?,
    pathKind: MirageCore.MirageNetworkPathKind?
) -> Int {
    let preferred = miragePreferredMediaMaxPacketSize(for: pathKind)
    let requestedSize = requested ?? preferred
    let clampedRequestedSize = max(
        MirageWire.mirageDefaultMaxPacketSize,
        min(mirageDirectLocalMaxPacketSize, requestedSize)
    )
    return min(preferred, clampedRequestedSize)
}

package func mirageNegotiatedMediaMaxPacketSize(
    requested: Int?,
    mediaPathProfile: MirageMedia.MirageMediaPathProfile?,
    pathKind: MirageCore.MirageNetworkPathKind?
) -> Int {
    let preferred = miragePreferredMediaMaxPacketSize(for: mediaPathProfile, pathKind: pathKind)
    let requestedSize = requested ?? preferred
    let clampedRequestedSize = max(
        MirageWire.mirageDefaultMaxPacketSize,
        min(mirageDirectLocalMaxPacketSize, requestedSize)
    )
    return min(preferred, clampedRequestedSize)
}
