//
//  MirageClientService+WindowList.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Window list request helper.
//

import MirageKit

@MainActor
public extension MirageClientService {
    /// Request updated window list from host.
    func requestWindowList() async throws {
        try await sendControlMessage(ControlMessage(type: .windowListRequest))
    }
}
