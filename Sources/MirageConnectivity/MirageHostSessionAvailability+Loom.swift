//
//  MirageHostSessionAvailability+Loom.swift
//  MirageConnectivity
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Loom
import MirageWire

package extension MirageHostSessionAvailability {
    init(loomAvailability: LoomSessionAvailability) {
        switch loomAvailability {
        case .ready:
            self = .ready
        case .credentialsRequired:
            self = .credentialsRequired
        case .credentialsAndUserIdentifierRequired:
            self = .credentialsAndUserIdentifierRequired
        case .unavailable:
            self = .unavailable
        }
    }

    var loomAvailability: LoomSessionAvailability {
        switch self {
        case .ready:
            .ready
        case .credentialsRequired:
            .credentialsRequired
        case .credentialsAndUserIdentifierRequired:
            .credentialsAndUserIdentifierRequired
        case .unavailable:
            .unavailable
        }
    }
}
