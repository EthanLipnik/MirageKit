//
//  MirageInput.MirageActionPreferences.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 4/6/26.
//

import MirageConnectivity
import MirageCore
import MirageDiagnostics
import MirageIdentity
import MirageInput
import MirageMedia
import MirageWire
import Foundation


// MARK: - UserDefaults Persistence

public extension MirageInput.MirageActionPreferences {
    private static let userDefaultsKey = "MirageInput.MirageActionPreferences"

    /// Loads saved action preferences and merges them with current built-in actions.
    static func load() -> MirageInput.MirageActionPreferences {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey) else {
            return MirageInput.MirageActionPreferences()
        }
        let prefs: MirageInput.MirageActionPreferences
        do {
            prefs = try JSONDecoder().decode(MirageInput.MirageActionPreferences.self, from: data)
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to decode action preferences: ")
            return MirageInput.MirageActionPreferences()
        }
        return MirageInput.MirageActionPreferences(actions: normalizedLoadedActions(prefs.actions))
    }

    /// Saves the action preferences to the standard user defaults store.
    func save() {
        do {
            let data = try JSONEncoder().encode(self)
            UserDefaults.standard.set(data, forKey: Self.userDefaultsKey)
        } catch {
            MirageLogger.error(.appState, error: error, message: "Failed to encode action preferences: ")
        }
    }
}
