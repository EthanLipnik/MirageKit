//
//  MirageHostService+AppStreaming+CloseBlockedAlerts.swift
//  MirageKit
//
//  Created by Ethan Lipnik on 2/28/26.
//
//  Host-side close-attempt + actionable alert routing for client window close events.
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
import Foundation
import CoreGraphics

#if os(macOS)

@MainActor
extension MirageHostService {
    nonisolated static func appWindowCloseAlertPresentingStreamID(
        activeStreams: [MirageStreamSession],
        clientID: UUID,
        excludingStreamID: StreamID
    ) -> StreamID? {
        activeStreams
            .filter { stream in
                stream.client.id == clientID &&
                    stream.id != excludingStreamID &&
                    stream.window.id != 0
            }
            .min { lhs, rhs in
                if lhs.id != rhs.id {
                    return lhs.id < rhs.id
                }
                return lhs.window.id < rhs.window.id
            }
            .map(\.id)
    }

    func handleHostWindowCloseAttemptForClientWindowClose(
        session: MirageStreamSession,
        appSession: MirageAppStreamSession
    ) async {
        let closeResult: HostWindowCloseAttemptResult
        do {
            closeResult = try await platformInputInjectionBackend.closeWindow(session.window)
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to close host window through input backend: ")
            return
        }

        switch closeResult {
        case .closed:
            MirageLogger.host(
                "Closed host window \(session.window.id) after client closed stream window (bundle=\(appSession.bundleIdentifier))"
            )
        case let .blocked(alert):
            await emitCloseBlockedAlertIfPossible(
                session: session,
                appSession: appSession,
                alert: alert
            )
        case .notClosed:
            break
        }
    }

    func performAppWindowCloseAlertAction(
        alertToken: String,
        actionID: String,
        presentingStreamID: StreamID,
        clientID: UUID
    ) async -> MirageWire.AppWindowCloseAlertActionResultMessage {
        let token = alertToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token is empty"
            )
        }

        guard let pending = pendingAppWindowCloseAlertTokensByToken[token] else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token expired"
            )
        }

        guard pending.clientID == clientID else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Alert token does not belong to this client"
            )
        }

        guard pending.presentingStreamID == presentingStreamID else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Presenting stream mismatch"
            )
        }

        guard activeStreams.contains(where: { $0.id == presentingStreamID && $0.client.id == clientID }) else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Presenting stream is no longer active"
            )
        }

        guard let action = pending.actions.first(where: { $0.id == actionID }) else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Requested alert action is unavailable"
            )
        }

        let pressed: Bool
        do {
            pressed = try await platformInputInjectionBackend.pressBlockingAlertAction(
                in: Self.pendingCloseAlertWindow(for: pending),
                actionIndex: action.index,
                fallbackTitle: action.title
            )
        } catch {
            MirageLogger.error(.host, error: error, message: "Failed to press host close-alert action: ")
            pressed = false
        }
        guard pressed else {
            return MirageWire.AppWindowCloseAlertActionResultMessage(
                alertToken: alertToken,
                actionID: actionID,
                success: false,
                reason: "Failed to perform host alert action"
            )
        }

        pendingAppWindowCloseAlertTokensByToken.removeValue(forKey: token)
        return MirageWire.AppWindowCloseAlertActionResultMessage(
            alertToken: alertToken,
            actionID: actionID,
            success: true,
            reason: nil
        )
    }

    func clearPendingAppWindowCloseAlertTokens(forClientID clientID: UUID) {
        pendingAppWindowCloseAlertTokensByToken = pendingAppWindowCloseAlertTokensByToken.filter { entry in
            entry.value.clientID != clientID
        }
    }

    func clearAllPendingAppWindowCloseAlertTokens() {
        pendingAppWindowCloseAlertTokensByToken.removeAll()
    }

    private nonisolated static func pendingCloseAlertWindow(
        for pending: PendingAppWindowCloseAlertToken
    ) -> MirageMedia.MirageWindow {
        MirageMedia.MirageWindow(
            id: pending.sourceWindowID,
            title: nil,
            application: pending.sourceApp,
            frame: .zero,
            isOnScreen: true,
            windowLayer: 0
        )
    }

    private func clearPendingAppWindowCloseAlertTokens(
        forClientID clientID: UUID,
        sourceWindowID: WindowID
    ) {
        pendingAppWindowCloseAlertTokensByToken = pendingAppWindowCloseAlertTokensByToken.filter { entry in
            !(entry.value.clientID == clientID && entry.value.sourceWindowID == sourceWindowID)
        }
    }

    private func emitCloseBlockedAlertIfPossible(
        session: MirageStreamSession,
        appSession: MirageAppStreamSession,
        alert: HostWindowCloseAlertSnapshot
    ) async {
        guard let presentingStreamID = Self.appWindowCloseAlertPresentingStreamID(
            activeStreams: activeStreams,
            clientID: session.client.id,
            excludingStreamID: session.id
        ) else {
            return
        }

        guard let clientContext = findClientContext(clientID: session.client.id) else {
            return
        }

        let mappedActions = alert.actions.map { action in
            let id = "action-\(action.index)"
            return PendingAppWindowCloseAlertAction(
                id: id,
                title: action.title,
                isDestructive: action.isDestructive,
                index: action.index
            )
        }
        guard !mappedActions.isEmpty else { return }

        let token = UUID().uuidString.lowercased()
        clearPendingAppWindowCloseAlertTokens(forClientID: session.client.id, sourceWindowID: session.window.id)
        pendingAppWindowCloseAlertTokensByToken[token] = PendingAppWindowCloseAlertToken(
            clientID: session.client.id,
            sourceWindowID: session.window.id,
            sourceApp: session.window.application,
            presentingStreamID: presentingStreamID,
            actions: mappedActions
        )

        let message = MirageWire.AppWindowCloseBlockedAlertMessage(
            bundleIdentifier: appSession.bundleIdentifier,
            sourceWindowID: session.window.id,
            presentingStreamID: presentingStreamID,
            alertToken: token,
            title: alert.title,
            message: alert.message,
            actions: mappedActions.map { action in
                MirageWire.AppWindowCloseBlockedAlertMessage.Action(
                    id: action.id,
                    title: action.title,
                    isDestructive: action.isDestructive
                )
            }
        )
        do {
            try await clientContext.send(.appWindowCloseBlockedAlert, content: message)
        } catch {
            pendingAppWindowCloseAlertTokensByToken.removeValue(forKey: token)
            MirageLogger.error(.host, error: error, message: "Failed to send app-window close blocked alert: ")
        }
    }
}

#endif
