//
//  AppStreamManager+SessionSlots.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/12/26.
//

import Foundation
import MirageKit

#if os(macOS)
extension AppStreamManager {
    /// Resolves the visible slot index to use for a stream binding.
    func resolvedSlotIndex(
        session: MirageAppStreamSession,
        streamID: StreamID,
        preferredSlotIndex: Int?
    ) -> Int? {
        if let existingSlot = session.windowStreams
            .first(where: { $0.value.streamID == streamID })?
            .value
            .slotIndex {
            return existingSlot
        }

        if let preferredSlotIndex,
           preferredSlotIndex >= 0,
           preferredSlotIndex < session.maxVisibleSlots,
           !usedVisibleSlots(in: session).contains(preferredSlotIndex) {
            return preferredSlotIndex
        }

        return firstAvailableVisibleSlot(in: session)
    }

    /// Returns visible slot indices currently bound in an app session.
    func usedVisibleSlots(in session: MirageAppStreamSession) -> Set<Int> {
        Set(session.windowStreams.values.map(\.slotIndex))
    }

    /// Returns the first visible slot not currently bound in an app session.
    func firstAvailableVisibleSlot(in session: MirageAppStreamSession) -> Int? {
        let usedSlots = usedVisibleSlots(in: session)
        return (0 ..< session.maxVisibleSlots).first { !usedSlots.contains($0) }
    }

    /// Returns the visible window binding for a stream ID within one app session.
    func visibleWindowBinding(
        in session: MirageAppStreamSession,
        streamID: StreamID
    ) -> (windowID: WindowID, info: WindowStreamInfo)? {
        guard let entry = session.windowStreams.first(where: { $0.value.streamID == streamID }) else {
            return nil
        }
        return (entry.key, entry.value)
    }

    /// Sorts hidden windows by display title, then window ID for deterministic inventory updates.
    func hiddenInventoryWindowPrecedes(
        _ lhs: AppWindowInventoryMessage.WindowMetadata,
        _ rhs: AppWindowInventoryMessage.WindowMetadata
    ) -> Bool {
        let lhsTitle = lhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let rhsTitle = rhs.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if lhsTitle.caseInsensitiveCompare(rhsTitle) != .orderedSame {
            return lhsTitle.caseInsensitiveCompare(rhsTitle) == .orderedAscending
        }
        return lhs.windowID < rhs.windowID
    }
}
#endif
