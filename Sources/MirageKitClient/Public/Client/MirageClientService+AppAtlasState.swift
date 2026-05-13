//
//  MirageClientService+AppAtlasState.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import MirageKit

@MainActor
extension MirageClientService {
    /// Stores host-provided atlas layouts and updates logical sessions that share the media stream.
    func storeAppAtlasLayouts(_ layouts: [MirageAppAtlasLayout]?) {
        guard let layouts else { return }
        for layout in layouts {
            storeAppAtlasLayout(layout)
        }
    }

    /// Stores a single app-atlas layout by media stream and layout epoch.
    func storeAppAtlasLayout(_ layout: MirageAppAtlasLayout) {
        appAtlasLayoutsByMediaStreamID[layout.mediaStreamID, default: [:]][layout.layoutEpoch] = layout
        sessionStore.updateSessionAtlasRegions(
            mediaStreamID: layout.mediaStreamID,
            layout: layout
        )
    }
}
