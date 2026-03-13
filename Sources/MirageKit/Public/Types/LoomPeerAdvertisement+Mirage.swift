//
//  LoomPeerAdvertisement+Mirage.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 3/9/26.
//

import Loom

public extension LoomPeerAdvertisement {
    var mirageMaxStreams: Int {
        MiragePeerAdvertisementMetadata.maxStreams(from: self)
    }

    var mirageSupportsHEVC: Bool {
        MiragePeerAdvertisementMetadata.supportsHEVC(in: self)
    }

    var mirageSupportsP3ColorSpace: Bool {
        MiragePeerAdvertisementMetadata.supportsP3ColorSpace(in: self)
    }

    var mirageSupportedColorDepths: [MirageStreamColorDepth] {
        MiragePeerAdvertisementMetadata.supportedColorDepths(in: self)
    }

    var mirageSupportsUltraColorDepth: Bool {
        mirageSupportedColorDepths.contains(.ultra)
    }

    var mirageMaxFrameRate: Int {
        MiragePeerAdvertisementMetadata.maxFrameRate(from: self)
    }
}
