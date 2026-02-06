//
//  ApplicationScanner+Filtering.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 1/24/26.
//
//  Application scanning helpers.
//

import MirageKit
#if os(macOS)
import CoreServices
import Foundation

// MARK: - Filtering Logic

extension ApplicationScanner {
    func shouldConsiderApp(at url: URL, allowBundleContents: Bool) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }

        if !allowBundleContents, url.path.contains("/Contents/") { return false }

        guard allowBundleContents else { return true }

        let components = url.pathComponents.map { $0.lowercased() }
        let residesInApplications = components.contains { component in
            component.contains("applications") || component.contains("utilities")
        }

        if !residesInApplications { return false }

        let isSimulatorRuntime = components.contains { component in
            component.contains(".simruntime") ||
                component.contains("coresimulator") ||
                component.contains("runtimeroot")
        }

        return !isSimulatorRuntime
    }

    func shouldIgnoreNestedDirectory(named name: String) -> Bool {
        let lowercased = name.lowercased()

        if excludedDirectoryNames.contains(lowercased) { return true }

        if lowercased.hasSuffix(".lproj") || lowercased.hasSuffix(".bundle") { return true }

        if lowercased.hasPrefix(".") { return true }

        return false
    }

    func shouldDescendThroughTransitDirectory(named name: String) -> Bool {
        if name.hasSuffix(".platform") { return true }

        switch name {
        case "contents",
             "developer",
             "extras",
             "platforms",
             "resources",
             "sharedsupport",
             "support":
            return true
        default:
            return false
        }
    }

    func allowsScanningBundleContents(at url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "app" else { return false }

        guard let bundle = Bundle(url: url),
              let identifier = bundle.bundleIdentifier?.lowercased() else {
            return false
        }

        return nestedBundleAllowedIdentifiers.contains(identifier)
    }
}

#endif
