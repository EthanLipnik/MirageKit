//
//  Logger+Convenience.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 5/10/26.
//

import Foundation

/// Convenience functions for common log patterns.
public extension MirageLogger {
    /// Log timing information, such as frame processing or encoding duration.
    static func timing(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.timing, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log pipeline throughput metrics.
    static func metrics(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.metrics, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log capture engine events.
    static func capture(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.capture, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log encoder events.
    static func encoder(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.encoder, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log decoder events.
    static func decoder(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.decoder, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log client events.
    static func client(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.client, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log host events.
    static func host(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.host, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log app state events.
    static func appState(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.appState, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log renderer events.
    static func renderer(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.renderer, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log stream lifecycle events.
    static func stream(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.stream, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log discovery events.
    static func discovery(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.discovery, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log network events.
    static func network(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.network, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log menu bar passthrough events.
    static func menuBar(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.menuBar, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log bootstrap orchestration events.
    static func bootstrap(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.bootstrap, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log SSH bootstrap events.
    static func ssh(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.ssh, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log Wake-on-LAN events.
    static func wol(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.wol, message: message, fileID: fileID, line: line, function: function)
    }

    /// Log bootstrap handoff events.
    static func bootstrapHandoff(
        _ message: @autoclosure () -> String,
        fileID: String = #fileID,
        line: UInt = #line,
        function: String = #function
    ) {
        logInfo(.bootstrapHandoff, message: message, fileID: fileID, line: line, function: function)
    }
}
