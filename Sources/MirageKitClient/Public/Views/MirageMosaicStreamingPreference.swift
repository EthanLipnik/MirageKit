//
//  MirageMosaicStreamingPreference.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/7/26.
//
//  Client preference for opting into the experimental Mosaic media path.
//

import Foundation

/// Preference namespace for opting into experimental Mosaic streaming.
public enum MirageMosaicStreamingPreference {
    /// UserDefaults key for requesting the experimental Mosaic media path.
    public static let defaultsKey = "mosaicStreamingEnabled"
}
