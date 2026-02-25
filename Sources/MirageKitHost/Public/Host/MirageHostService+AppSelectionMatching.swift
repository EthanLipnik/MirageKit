//
//  MirageHostService+AppSelectionMatching.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/25/26.
//
//  App selection window matching helpers.
//

import Foundation
import MirageKit

#if os(macOS)
import AppKit

extension MirageHostService {
    func windowMatchesSelectedAppWindow(_ window: MirageWindow, bundleIdentifier: String) -> Bool {
        let normalizedBundleID = bundleIdentifier.lowercased()
        if window.application?.bundleIdentifier?.lowercased() == normalizedBundleID { return true }

        guard let pid = window.application?.id else { return false }
        let runningPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier?.lowercased() == normalizedBundleID }
                .map(\.processIdentifier)
        )
        return runningPIDs.contains(pid)
    }
}
#endif
