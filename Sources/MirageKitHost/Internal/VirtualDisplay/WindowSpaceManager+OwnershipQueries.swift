//
//  WindowSpaceManager+OwnershipQueries.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/9/26.
//
//  Pure ownership helpers for saved window state.
//


import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageKit
import MirageKitClientPresentation
import MirageMedia
import MirageWire
#if os(macOS)
extension WindowSpaceManager {
    nonisolated static func validateRestoreOwner(
        expectedOwner: WindowBindingOwner?,
        savedOwner: WindowBindingOwner?
    ) -> RestoreOwnerValidationResult {
        guard let expectedOwner else { return .allowed }
        guard let savedOwner else {
            return .ownerMismatch(
                expectedStreamID: expectedOwner.streamID,
                actualStreamID: StreamID(0)
            )
        }
        guard savedOwner.streamID == expectedOwner.streamID else {
            return .ownerMismatch(
                expectedStreamID: expectedOwner.streamID,
                actualStreamID: savedOwner.streamID
            )
        }
        return .allowed
    }

    nonisolated static func claimedWindowIDsForActiveOwners(
        from savedStates: [WindowID: SavedWindowState],
        activeStreamIDs: Set<StreamID>
    ) -> Set<WindowID> {
        Set(savedStates.compactMap { windowID, state in
            guard let owner = state.owner,
                  activeStreamIDs.contains(owner.streamID) else {
                return nil
            }
            return windowID
        })
    }

    nonisolated static func windowIDsOwned(
        by streamID: StreamID,
        from savedStates: [WindowID: SavedWindowState]
    ) -> Set<WindowID> {
        Set(savedStates.compactMap { windowID, state in
            guard state.owner?.streamID == streamID else { return nil }
            return windowID
        })
    }
}
#endif
