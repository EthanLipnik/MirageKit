//
//  StreamContext+MediaSendProfile.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/25/26.
//

import Loom
import MirageKit

#if os(macOS)
extension StreamContext {
    func setMediaSendProfile(_ profile: LoomQueuedUnreliableSendProfile) {
        let limits = profile.recommendedLimits
        mediaSendProfileRawValue = profile.rawValue
        mediaSendProfileMaxOutstandingPackets = limits.maxOutstandingPackets
        mediaSendProfileMaxOutstandingBytes = limits.maxOutstandingBytes
        mediaSendProfileMaxQueuedPackets = limits.maxQueuedPackets
    }
}
#endif
