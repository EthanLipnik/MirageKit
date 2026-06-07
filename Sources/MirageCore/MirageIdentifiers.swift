//
//  MirageIdentifiers.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 6/5/26.
//

import Foundation

/// Stable identifier for a host window in Mirage protocol messages.
public typealias WindowID = UInt32

/// Stable identifier for a media stream within a Mirage session.
public typealias StreamID = UInt16

/// Stable identifier for a logical stream session across control messages.
public typealias StreamSessionID = UUID

/// Stable identity for one logical stream presentation.
public typealias StreamPresentationID = UUID
