//
//  ApplicationScanner+VersionComparison.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Application scanning helpers.
//

import CoreServices
import Foundation
import MirageKit

// MARK: - Version Comparison

private func compareVersions(_ lhs: String?, _ rhs: String?) -> ComparisonResult? {
    switch (lhs, rhs) {
    case (nil, nil):
        return .orderedSame
    case let (lhs?, rhs?):
        if lhs == rhs { return .orderedSame }

        let lhsComponents = lhs.split(separator: ".")
        let rhsComponents = rhs.split(separator: ".")
        let maxCount = max(lhsComponents.count, rhsComponents.count)

        for index in 0 ..< maxCount {
            let lhsValue = index < lhsComponents.count ? lhsComponents[index] : "0"
            let rhsValue = index < rhsComponents.count ? rhsComponents[index] : "0"

            if let lhsInt = Int(lhsValue), let rhsInt = Int(rhsValue) {
                if lhsInt != rhsInt { return lhsInt < rhsInt ? .orderedAscending : .orderedDescending }
            } else {
                let comparison = lhsValue.localizedStandardCompare(rhsValue)
                if comparison != .orderedSame { return comparison }
            }
        }

        return .orderedSame
    case (nil, .some):
        return .orderedAscending
    case (.some, nil):
        return .orderedDescending
    }
}
