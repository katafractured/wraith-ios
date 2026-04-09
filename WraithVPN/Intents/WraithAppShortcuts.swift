// WraithAppShortcuts.swift
// WraithVPN
//
// Registers App Shortcuts so "Connect WraithVPN" and "Disconnect WraithVPN"
// appear in Spotlight, Siri, and the Shortcuts app without opening the app.

import AppIntents

struct WraithAppShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: [
                "Connect \(.applicationName)",
                "Turn on \(.applicationName)",
                "\(.applicationName) connect",
            ],
            shortTitle: "Connect",
            systemImageName: "shield.fill"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: [
                "Disconnect \(.applicationName)",
                "Turn off \(.applicationName)",
                "\(.applicationName) disconnect",
            ],
            shortTitle: "Disconnect",
            systemImageName: "shield.slash"
        )
    }
}
